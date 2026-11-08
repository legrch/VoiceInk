#!/usr/bin/env python3
"""Publish one new immutable release after source, hash and ordering checks."""
import hashlib, json, re, subprocess, sys, tempfile
from pathlib import Path

def require(condition, message='Validation failed'):
    if not condition:
        raise RuntimeError(message)
REPO = 'legrch/VoiceInk'

def gh(*args):
    return subprocess.check_output(['gh', *args], text=True)

def prepare(directory, tag, source):
    require(re.fullmatch('plus-v[0-9]+(?:\\.[0-9]+){1,2}-r[1-9][0-9]*', tag), 'Validation failed')
    require(re.fullmatch('[a-f0-9]{40}', source), 'Validation failed')
    m = json.loads((directory / 'release.json').read_text())
    require(m['tag'] == tag and m['source_commit'] == source and (type(m['build']) is int) and (225 < m['build'] < 2147483647), 'Validation failed')
    require(re.fullmatch('[0-9]+(?:\\.[0-9]+){1,2}', m['upstream_version']), 'Validation failed')
    require(type(m['revision']) is int and m['revision'] > 0, 'Validation failed')
    require(tag == f"plus-v{m['upstream_version']}-r{m['revision']}", 'Validation failed')
    require(m['asset'] == f"VoiceInk-Plus-{m['upstream_version']}-r{m['revision']}-AppleSilicon.zip", 'Validation failed')
    require(re.fullmatch('VoiceInk-Plus-[0-9]+(?:\\.[0-9]+){1,2}-r[1-9][0-9]*-AppleSilicon\\.zip', m['asset']), 'Validation failed')
    archive = directory / m['asset']
    require(hashlib.sha256(archive.read_bytes()).hexdigest() == m['archive_sha256'], 'Archive mismatch')
    obj = json.loads(gh('api', f'repos/{REPO}/git/ref/tags/{tag}'))['object']
    for _ in range(4):
        if obj['type'] == 'commit':
            break
        require(obj['type'] == 'tag' and re.fullmatch('[a-f0-9]{40}', obj['sha']), 'Validation failed')
        obj = json.loads(gh('api', f"repos/{REPO}/git/tags/{obj['sha']}"))['object']
    require(obj['type'] == 'commit' and obj['sha'] == source, 'Tag moved after build')
    latest = json.loads(gh('api', f'repos/{REPO}/releases/latest'))['tag_name']
    require(latest != tag, 'Release already exists')
    if latest == 'plus-v2.25-r3':
        old_build = 1003
    else:
        require(re.fullmatch('plus-v[0-9]+(?:\\.[0-9]+){1,2}-r[1-9][0-9]*', latest), 'Validation failed')
        with tempfile.TemporaryDirectory() as temporary:
            subprocess.run(['gh', 'release', 'download', latest, '--repo', REPO, '--pattern', 'release.json', '--dir', temporary], check=True)
            old_build = json.loads((Path(temporary) / 'release.json').read_text())['build']
        require(type(old_build) is int, 'Validation failed')
    require(m['build'] > old_build, 'Refusing out-of-order publication or build reuse')
    files = [archive, directory / 'release.json', directory / 'install.sh', directory / 'SHA256SUMS']
    require(all((p.is_file() and (not p.is_symlink()) for p in files)), 'Validation failed')
    return files

def main():
    directory = Path(sys.argv[1]).resolve()
    tag = sys.argv[2]
    source = sys.argv[3]
    files = prepare(directory, tag, source)
    subprocess.run(['shasum', '-a', '256', '-c', 'SHA256SUMS'], cwd=directory, check=True)
    notes = directory / 'notes.txt'
    notes.write_text('Apple Silicon · macOS 15+ · locally signed, not Apple-notarized.\n\nQuit VoiceInk, then install/update with:\n\n```sh\ncurl -fsSL https://raw.githubusercontent.com/legrch/VoiceInk/main/scripts/install-release.sh | sh -s -- latest\n```\n\nThe installer preserves a rollback copy. Automatic in-app updates remain disabled.\n')
    subprocess.run(['gh', 'release', 'create', tag, *map(str, files), '--repo', REPO, '--verify-tag', '--title', f'VoiceInk Plus {tag}', '--notes-file', str(notes), '--latest'], check=True)
if __name__ == '__main__':
    main()
