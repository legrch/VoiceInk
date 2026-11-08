#!/usr/bin/env python3
"""Stamp a copied app before its caller signs it; never sign, install or launch."""
import os, plistlib, re, sys
from pathlib import Path
from release_identity import effective_metadata, info_fields

def require(condition, message='Validation failed'):
    if not condition:
        raise RuntimeError(message)
app = Path(sys.argv[1])
mode = sys.argv[2]
source = sys.argv[3]
description = sys.argv[4]
require(app.name == 'VoiceInk.app' and mode in ('dev', 'ci', 'release') and re.fullmatch('[a-f0-9]{40}', source), 'Validation failed')
require(mode == 'release' or 'VOICEINK_RELEASE_METADATA' not in os.environ, 'Release metadata override requires release mode')
path = app / 'Contents/Info.plist'
require(path.is_file() and not path.is_symlink(), 'Copied app plist must be a regular file')
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
    if 'VOICEINK_RELEASE_METADATA' in os.environ:
        info.update(info_fields(effective_metadata(Path(__file__).resolve().parent.parent, source)))
path.write_bytes(plistlib.dumps(info, sort_keys=False))
