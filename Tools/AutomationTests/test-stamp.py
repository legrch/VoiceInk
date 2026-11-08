import json,plistlib,subprocess,tempfile
from pathlib import Path
base=plistlib.loads(Path('VoiceInk/Info.plist').read_bytes());base['CFBundleIdentifier']='com.prakashjoshipax.VoiceInk'
with tempfile.TemporaryDirectory(prefix='voiceink-stamp-tests-',dir='/private/tmp') as scratch:
    root=Path(scratch);app=root/'VoiceInk.app';(app/'Contents').mkdir(parents=True);path=app/'Contents/Info.plist'
    for existing in [False,True]:
        info=base.copy()
        if existing:info['CFBundleDisplayName']='VoiceInk'
        path.write_bytes(plistlib.dumps(info))
        subprocess.run(['python3','scripts/stamp-build.py',str(app),'dev','1'*40,'plus-v2.25-r3-1-gabcdef0'],check=True)
        result=plistlib.loads(path.read_bytes())
        assert result['CFBundleDisplayName']=='VoiceInk Dev' and result['VoiceInkSourceCommit']=='1'*40
        package=subprocess.run(['python3','scripts/plus-release.py','package','--app',str(app),'--output',str(root/'assets')],capture_output=True,text=True)
        assert package.returncode!=0 and 'Refusing to package a development app' in package.stderr
    path.write_bytes(plistlib.dumps(base))
    subprocess.run(['python3','scripts/stamp-build.py',str(app),'release','2'*40,'ignored'],check=True)
    assert 'VoiceInkDevDescription' not in plistlib.loads(path.read_bytes())
print('Dev display stamping, source identity and prevention of Dev publication passed')
