#!/bin/bash
# Owner-invoked, one-time transfer of the selected identity; never run from CI.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
if [[ ${1:-} != --upload || $# != 1 ]]; then
  echo 'Usage: scripts/configure-ci-signing.sh --upload'
  echo 'With explicit owner approval, export only the existing VoiceInk identity and upload two encrypted GitHub environment secrets.'
  exit 0
fi
command -v gh >/dev/null
work=$(mktemp -d /private/tmp/voiceink-signing-setup.XXXXXX)
trap 'rm -rf "$work"' EXIT
swiftc Tools/CISigning/EnvironmentPolicy.swift Tools/CISigning/main.swift -o "$work/configure"
"$work/configure" --upload
