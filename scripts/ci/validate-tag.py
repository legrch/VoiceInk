#!/usr/bin/env python3
"""Validate a release tag and main ancestry without modifying Git or a release."""
import argparse, json, subprocess, re
from pathlib import Path

def require(condition, message='Validation failed'):
    if not condition:
        raise RuntimeError(message)
p = argparse.ArgumentParser()
p.add_argument('tag')
p.add_argument('--dry-run', action='store_true')
a = p.parse_args()
m = json.loads(Path('release/plus.json').read_text())
expected = f"plus-v{m['upstream_version']}-r{m['revision']}"
require(re.fullmatch('plus-v[0-9]+(?:\\.[0-9]+){1,2}-r[1-9][0-9]*', a.tag) and a.tag == expected, 'Tag must match release/plus.json')
head = subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip()
subprocess.run(['git', 'fetch', 'origin', 'main'], check=True)
subprocess.run(['git', 'merge-base', '--is-ancestor', head, 'origin/main'], check=True)
subprocess.run(['python3', 'scripts/plus-release.py', 'check'], check=True)
if not a.dry_run:
    existing = subprocess.run(['gh', 'release', 'view', a.tag, '--json', 'tagName'], capture_output=True, text=True)
    require(existing.returncode != 0, 'Release already exists; never replace its assets')
    latest = subprocess.run(['gh', 'api', 'repos/legrch/VoiceInk/releases/latest'], capture_output=True, text=True, check=True)
    published = json.loads(latest.stdout)
    old_tag = published['tag_name']
    old_text = subprocess.check_output(['git', 'show', f'{old_tag}:release/plus.json'], text=True)
    require(m['build'] > json.loads(old_text)['build'], 'Release build must increase monotonically')
print('Validated tag, source ancestry and release identity:', a.tag, head)
