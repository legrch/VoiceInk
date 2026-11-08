#!/usr/bin/env python3
"""Request server-side release orchestration; never edit files or local Git refs."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess

REPO = 'legrch/VoiceInk'
ROOT = Path(__file__).resolve().parent.parent


def api(path, data=None):
    args = ['gh', 'api', f'repos/{REPO}/{path}', '-H', 'X-GitHub-Api-Version: 2026-03-10']
    if data is not None:
        args += ['--method', 'POST', '--input', '-']
    env = dict(os.environ, GH_HOST='github.com')
    env.pop('GH_DEBUG', None)
    result = subprocess.run(args, input=None if data is None else json.dumps(data),
                            text=True, capture_output=True, env=env)
    if result.returncode:
        raise RuntimeError('GitHub request failed. Inspect Actions before repeating a dispatch; no automatic retry was made.')
    if not result.stdout.strip():
        raise RuntimeError(f'Dispatch outcome has no run receipt. Inspect https://github.com/{REPO}/actions/workflows/release.yml before retrying.')
    return json.loads(result.stdout)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dry-run', action='store_true', help='Build and verify without reserving a tag or publishing')
    args = parser.parse_args()
    origin = subprocess.check_output(['git', 'remote', 'get-url', 'origin'], cwd=ROOT, text=True).strip()
    if origin not in ('git@github.com:legrch/VoiceInk.git', 'https://github.com/legrch/VoiceInk.git'):
        raise RuntimeError('Release requests only target the existing legrch/VoiceInk origin.')
    source = api('git/ref/heads/main')['object']['sha']
    if not isinstance(source, str) or not re.fullmatch(r'[a-f0-9]{40}', source):
        raise RuntimeError('Invalid GitHub main identity.')
    mode = 'dry-run' if args.dry_run else 'publish'
    print(f'Requesting {mode} from GitHub main at {source}; local files are not uploaded.', flush=True)
    receipt = api('actions/workflows/release.yml/dispatches', {'ref': 'main', 'inputs': {'mode': mode, 'expected_source': source}})
    run = receipt.get('workflow_run_id')
    url = receipt.get('html_url')
    if type(run) is not int or run <= 0 or url != f'https://github.com/{REPO}/actions/runs/{run}':
        raise RuntimeError('Unrecognized dispatch receipt; inspect the original workflow instead of dispatching again.')
    print(f'Requested (not yet released): {url}')
    print('GitHub continues after this command exits. Follow the run for Checks, signing approval and final publication.')


if __name__ == '__main__':
    main()
