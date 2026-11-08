"""Exercise release overrides without signing, building, or changing source files."""
import copy
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile

root = Path.cwd()
spec = importlib.util.spec_from_file_location('release_identity', root / 'scripts/release_identity.py')
identity = importlib.util.module_from_spec(spec)
spec.loader.exec_module(identity)
source = subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip()
base = identity.base_metadata(root)
override = dict(base, revision=base['revision'] + 1, build=base['build'] + 1, source_commit=source)
override['tag'] = f"plus-v{override['upstream_version']}-r{override['revision']}"
override['asset'] = f"VoiceInk-Plus-{override['upstream_version']}-r{override['revision']}-AppleSilicon.zip"
env = dict(os.environ, VOICEINK_RELEASE_METADATA=json.dumps(override))
os.environ.pop('VOICEINK_RELEASE_METADATA', None)
assert identity.effective_metadata(root, source) == base
os.environ['VOICEINK_RELEASE_METADATA'] = env['VOICEINK_RELEASE_METADATA']
assert identity.effective_metadata(root, source) == override

bad_cases = [
    ('source_commit', '1' * 40), ('upstream_version', '3.0'), ('upstream_commit', 'a' * 40),
    ('product', 'wrong'), ('tag', 'wrong'), ('asset', 'wrong'), ('revision', True),
    ('revision', 0), ('build', True), ('build', 225), ('build', base['build'] - 1),
    ('build', 2147483647), ('schema', True), ('extra', 'unexpected'),
]
for key, value in bad_cases:
    bad = copy.deepcopy(override); bad[key] = value
    os.environ['VOICEINK_RELEASE_METADATA'] = json.dumps(bad)
    try:
        identity.effective_metadata(root, source)
    except (ValueError, TypeError):
        pass
    else:
        raise AssertionError(f'accepted invalid {key}={value!r}')
for raw in ('', '{', '[]', '{"schema": 1, "schema": 1}', json.dumps({'source_commit': source}), ' ' * 16385):
    os.environ['VOICEINK_RELEASE_METADATA'] = raw
    try:
        identity.effective_metadata(root, source)
    except (ValueError, TypeError):
        pass
    else:
        raise AssertionError('accepted malformed override')
os.environ.pop('VOICEINK_RELEASE_METADATA', None)

tracked = [root / 'release/plus.json', root / 'VoiceInk/Info.plist', root / 'VoiceInk.xcodeproj/project.pbxproj']
before = [p.read_bytes() for p in tracked]
with tempfile.TemporaryDirectory(prefix='voiceink-release-identity-', dir='/private/tmp') as tmp:
    app = Path(tmp) / 'VoiceInk.app'; contents = app / 'Contents'; contents.mkdir(parents=True)
    info = plistlib.loads(before[1]); info['CFBundleIdentifier'] = 'com.prakashjoshipax.VoiceInk'
    plist = contents / 'Info.plist'; plist.write_bytes(plistlib.dumps(info))
    helper = contents / 'XPCServices/Test.xpc/Contents/Info.plist'; helper.parent.mkdir(parents=True)
    helper.write_bytes(plistlib.dumps({'CFBundleVersion': '1', 'CFBundleIdentifier': 'helper'})); helper_before = helper.read_bytes()
    for mode in ('dev', 'ci'):
        result = subprocess.run(['python3', 'scripts/stamp-build.py', str(app), mode, source, 'test'], env=env, capture_output=True)
        assert result.returncode != 0
    subprocess.run(['python3', 'scripts/stamp-build.py', str(app), 'release', source, 'test'], env=env, check=True)
    stamped = plistlib.loads(plist.read_bytes())
    assert all(stamped[k] == v for k, v in identity.info_fields(override).items())
    assert stamped['VoiceInkSourceCommit'] == source and stamped['CFBundleIdentifier'] == info['CFBundleIdentifier']
    assert 'SUFeedURL' not in stamped and helper.read_bytes() == helper_before
    subprocess.run(['python3', 'scripts/plus-release.py', 'check', '--app', str(app)], env=env, check=True)
    tools = Path(tmp) / 'bin'; tools.mkdir()
    codesign = tools / 'codesign'; codesign.write_text('#!/bin/sh\nexit 0\n'); codesign.chmod(0o755)
    ditto = tools / 'ditto'
    ditto.write_text('#!/bin/sh\nif [ "$1" = "-c" ]; then eval "out=\\${$#}"; printf fixture > "$out"; else cp -R "$1" "$2"; fi\n')
    ditto.chmod(0o755)
    package_env = dict(env, PATH=str(tools) + ':' + os.environ['PATH'])
    assets = Path(tmp) / 'assets'
    subprocess.run(['python3', 'scripts/plus-release.py', 'package', '--app', str(app), '--output', str(assets)], env=package_env, check=True)
    manifest = json.loads((assets / 'release.json').read_text())
    assert all(manifest[k] == override[k] for k in ('schema', 'upstream_version', 'revision', 'build', 'tag', 'asset', 'source_commit'))
    assert len(manifest['archive_sha256']) == 64
    stamped['VoiceInkSourceCommit'] = '0' * 40; plist.write_bytes(plistlib.dumps(stamped))
    assert subprocess.run(['python3', 'scripts/plus-release.py', 'check', '--app', str(app)], env=env, capture_output=True).returncode != 0
    for operation in ('sync-info', 'pin-installer', 'pin-bootstrap'):
        assert subprocess.run(['python3', 'scripts/plus-release.py', operation], env=env, capture_output=True).returncode != 0
assert [p.read_bytes() for p in tracked] == before
print('Release metadata validation and copied-app stamping passed')
