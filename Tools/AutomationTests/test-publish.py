import hashlib,importlib.util,json,subprocess,tempfile
from pathlib import Path
from unittest.mock import patch
spec=importlib.util.spec_from_file_location('publisher','scripts/ci/publish-release.py');m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
with tempfile.TemporaryDirectory(prefix='voiceink-publish-tests-',dir='/private/tmp') as scratch:
    root=Path(scratch);tag='plus-v2.25-r4';source='1'*40
    manifest=dict(schema=1,tag=tag,upstream_version='2.25',revision=4,build=1004,source_commit=source,
        asset='VoiceInk-Plus-2.25-r4-AppleSilicon.zip',archive_sha256=hashlib.sha256(b'fixture').hexdigest())
    (root/manifest['asset']).write_bytes(b'fixture')
    for name in ['install.sh','SHA256SUMS']:(root/name).write_text('fixture')
    def check(value,commit=source):
        (root/'release.json').write_text(json.dumps(value))
        def gh(*args):
            if 'releases/latest' in args[-1]:return json.dumps({'tag_name':'plus-v2.25-r3'})
            return json.dumps({'object':{'type':'commit','sha':commit}})
        with patch.object(m,'gh',side_effect=gh):return m.prepare(root,tag,source)
    assert len(check(manifest))==4
    for field,value in [('build',1003),('source_commit','2'*40),('asset','../../outside.zip'),('archive_sha256','0'*64),('revision',5)]:
        bad=manifest.copy();bad[field]=value
        try:check(bad)
        except AssertionError:pass
        else:raise AssertionError('Invalid publication accepted: '+field)
    try:check(manifest,commit='2'*40)
    except AssertionError:pass
    else:raise AssertionError('Moved tag accepted')
print('Publish provenance, moved tag, monotonic build and archive identity checks passed; no release created')
