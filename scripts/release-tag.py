#!/usr/bin/env python3
"""Push the release tag for an already merged, clean and checked manifest."""
import json, os, subprocess
from pathlib import Path

def require(condition, message='Validation failed'):
    if not condition:
        raise RuntimeError(message)
repo = Path(__file__).resolve().parent.parent
os.chdir(repo)

def git(*args):
    return subprocess.check_output(['git', *args], text=True).strip()
require(not git('status', '--porcelain'), 'Commit and integrate changes before release')
require(git('branch', '--show-current') == 'main', 'Release only from stable main')
require(git('remote', 'get-url', 'origin') in ('git@github.com:legrch/VoiceInk.git', 'https://github.com/legrch/VoiceInk.git'), 'Validation failed')
subprocess.run(['git', 'fetch', 'origin', 'main', '--tags'], check=True)
require(git('rev-parse', 'HEAD') == git('rev-parse', 'origin/main'), 'Local main must equal remote main')
m = json.loads(Path('release/plus.json').read_text())
tag = f"plus-v{m['upstream_version']}-r{m['revision']}"
subprocess.run(['python3', 'scripts/ci/validate-tag.py', tag], check=True)
require(subprocess.run(['git', 'show-ref', '--verify', '--quiet', f'refs/tags/{tag}']).returncode == 1, 'Tag already exists locally')
require(not git('ls-remote', '--tags', 'origin', f'refs/tags/{tag}'), 'Tag already exists remotely')
checks = json.loads(subprocess.check_output(['gh', 'api', f"repos/legrch/VoiceInk/commits/{git('rev-parse', 'HEAD')}/check-runs"], text=True))
require(all((c['status'] == 'completed' and c['conclusion'] in ('success', 'neutral', 'skipped') for c in checks['check_runs'])), 'A main check is pending or failed')
require(any((c['name'] == 'macos-build' and c['status'] == 'completed' and (c['conclusion'] == 'success') for c in checks['check_runs'])), 'Wait for the main macOS build check')
subprocess.run(['git', 'tag', '-a', tag, '-m', f'VoiceInk Plus {tag}'], check=True)
subprocess.run(['git', 'push', 'origin', f'refs/tags/{tag}'], check=True)
print('Tag pushed. Follow GitHub Actions Release; no force or asset replacement is used.')
