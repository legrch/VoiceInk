#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
python3 scripts/plus-release.py check
work=$(mktemp -d /private/tmp/voiceink-plus-tests.XXXXXXXX)
trap 'rm -rf "$work"' EXIT
swiftc VoiceInk/PersonalFeatures/Release/PlusReleaseMetadata.swift Tools/PlusReleaseTests/main.swift -o "$work/check"
"$work/check" VoiceInk/Info.plist
