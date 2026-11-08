#!/usr/bin/env python3
"""Publish one new immutable release after source, hash and ordering checks."""
import hashlib,json,re,subprocess,sys,tempfile
from pathlib import Path
REPO='legrch/VoiceInk'
def gh(*args):return subprocess.check_output(['gh',*args],text=True)
def prepare(directory,tag,source):
    assert re.fullmatch(r'plus-v[0-9]+(?:\.[0-9]+){1,2}-r[1-9][0-9]*',tag)
    assert re.fullmatch(r'[a-f0-9]{40}',source)
    m=json.loads((directory/'release.json').read_text())
    assert m['tag']==tag and m['source_commit']==source and type(m['build']) is int and 225<m['build']<2147483647
    assert re.fullmatch(r'[0-9]+(?:\.[0-9]+){1,2}',m['upstream_version'])
    assert type(m['revision']) is int and m['revision']>0
    assert tag==f"plus-v{m['upstream_version']}-r{m['revision']}"
    assert m['asset']==f"VoiceInk-Plus-{m['upstream_version']}-r{m['revision']}-AppleSilicon.zip"
    assert re.fullmatch(r'VoiceInk-Plus-[0-9]+(?:\.[0-9]+){1,2}-r[1-9][0-9]*-AppleSilicon\.zip',m['asset'])
    archive=directory/m['asset']
    assert hashlib.sha256(archive.read_bytes()).hexdigest()==m['archive_sha256'],'Archive mismatch'
    obj=json.loads(gh('api',f'repos/{REPO}/git/ref/tags/{tag}'))['object']
    for _ in range(4):
        if obj['type']=='commit':break
        assert obj['type']=='tag' and re.fullmatch(r'[a-f0-9]{40}',obj['sha'])
        obj=json.loads(gh('api',f'repos/{REPO}/git/tags/{obj["sha"]}'))['object']
    assert obj['type']=='commit' and obj['sha']==source,'Tag moved after build'
    latest=json.loads(gh('api',f'repos/{REPO}/releases/latest'))['tag_name']
    assert latest!=tag,'Release already exists'
    if latest=='plus-v2.25-r3':old_build=1003
    else:
        assert re.fullmatch(r'plus-v[0-9]+(?:\.[0-9]+){1,2}-r[1-9][0-9]*',latest)
        with tempfile.TemporaryDirectory() as temporary:
            subprocess.run(['gh','release','download',latest,'--repo',REPO,'--pattern','release.json','--dir',temporary],check=True)
            old_build=json.loads((Path(temporary)/'release.json').read_text())['build']
        assert type(old_build) is int
    assert m['build']>old_build,'Refusing out-of-order publication or build reuse'
    files=[archive,directory/'release.json',directory/'install.sh',directory/'SHA256SUMS']
    assert all(p.is_file() and not p.is_symlink() for p in files)
    return files

def main():
    directory=Path(sys.argv[1]).resolve();tag=sys.argv[2];source=sys.argv[3]
    files=prepare(directory,tag,source)
    subprocess.run(['shasum','-a','256','-c','SHA256SUMS'],cwd=directory,check=True)
    notes=directory/'notes.txt'
    notes.write_text('Apple Silicon · macOS 15+ · locally signed, not Apple-notarized.\n\nQuit VoiceInk, then install/update with:\n\n```sh\ncurl -fsSL https://raw.githubusercontent.com/legrch/VoiceInk/main/scripts/install-release.sh | sh -s -- latest\n```\n\nThe installer preserves a rollback copy. Automatic in-app updates remain disabled.\n')
    subprocess.run(['gh','release','create',tag,*map(str,files),'--repo',REPO,'--verify-tag','--title',f'VoiceInk Plus {tag}','--notes-file',str(notes),'--latest'],check=True)
if __name__=='__main__':main()
