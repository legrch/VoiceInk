#!/usr/bin/env python3
"""Require the hardened-runtime bit on the final app signature."""
import re
import subprocess
import sys


def require_runtime(description):
    matches = re.findall(r'^CodeDirectory[^\r\n]*\bflags=0x([0-9a-fA-F]{1,8})\(', description, re.MULTILINE)
    if len(matches) != 1 or not int(matches[0], 16) & 0x10000:
        raise RuntimeError('Final signature does not enable hardened runtime')


if __name__ == '__main__':
    if len(sys.argv) != 2:
        raise SystemExit('Usage: verify-runtime.py APP')
    result = subprocess.run(['codesign', '--display', '--verbose=4', sys.argv[1]], capture_output=True, text=True, check=True)
    require_runtime(result.stdout + result.stderr)
    print('Final signature enables hardened runtime')
