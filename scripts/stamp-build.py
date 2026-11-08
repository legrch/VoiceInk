#!/usr/bin/env python3
"""Stamp a copied app before its caller signs it; never sign, install or launch."""
import plistlib, re, sys
from pathlib import Path

def require(condition, message='Validation failed'):
    if not condition:
        raise RuntimeError(message)
app = Path(sys.argv[1])
mode = sys.argv[2]
source = sys.argv[3]
description = sys.argv[4]
require(app.name == 'VoiceInk.app' and mode in ('dev', 'ci', 'release') and re.fullmatch('[a-f0-9]{40}', source), 'Validation failed')
path = app / 'Contents/Info.plist'
info = plistlib.loads(path.read_bytes())
require(info['CFBundleIdentifier'] == 'com.prakashjoshipax.VoiceInk', 'Validation failed')
info['VoiceInkSourceCommit'] = source
if mode != 'release':
    require(re.fullmatch('[A-Za-z0-9._+-]{1,160}', description), 'Validation failed')
    info['VoiceInkDevDescription'] = description
    info['CFBundleDisplayName'] = 'VoiceInk Dev'
    info['CFBundleName'] = 'VoiceInk Dev'
else:
    require('VoiceInkDevDescription' not in info, 'Release input unexpectedly contains development metadata')
path.write_bytes(plistlib.dumps(info, sort_keys=False))
