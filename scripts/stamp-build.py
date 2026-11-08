#!/usr/bin/env python3
"""Stamp a copied app before its caller signs it; never sign, install or launch."""
import plistlib,re,sys
from pathlib import Path
app=Path(sys.argv[1]);mode=sys.argv[2];source=sys.argv[3];description=sys.argv[4]
assert app.name=='VoiceInk.app' and mode in ('dev','ci','release') and re.fullmatch(r'[a-f0-9]{40}',source)
path=app/'Contents/Info.plist';info=plistlib.loads(path.read_bytes())
assert info['CFBundleIdentifier']=='com.prakashjoshipax.VoiceInk'
info['VoiceInkSourceCommit']=source
if mode!='release':
    assert re.fullmatch(r'[A-Za-z0-9._+-]{1,160}',description)
    info['VoiceInkDevDescription']=description
    info['CFBundleDisplayName']='VoiceInk Dev';info['CFBundleName']='VoiceInk Dev'
else:assert 'VoiceInkDevDescription' not in info,'Release input unexpectedly contains development metadata'
path.write_bytes(plistlib.dumps(info,sort_keys=False))
