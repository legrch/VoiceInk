#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
archive=${1:?};manifest=${2:?}
fixture=$(mktemp -d /private/tmp/voiceink-manifest-install.XXXXXX)
trap 'rm -rf "$fixture"' EXIT
version=$(plutil -extract tag raw -o - "$manifest")
bash -c 'source scripts/install.sh; pgrep() { return 1; }; main --version "$1" --archive "$2" --manifest "$3" --destination "$4"' bash "$version" "$archive" "$manifest" "$fixture/VoiceInk.app"
codesign --verify --deep --strict "$fixture/VoiceInk.app"
original=$(shasum -a 256 "$fixture/VoiceInk.app/Contents/MacOS/VoiceInk" | cut -d' ' -f1)
if bash -c 'source scripts/install.sh; pgrep() { return 1; }; mv() { if [[ "$1" == */new.app ]]; then return 17; fi; command mv "$@"; }; main --version "$1" --archive "$2" --manifest "$3" --destination "$4"' bash "$version" "$archive" "$manifest" "$fixture/VoiceInk.app"; then
    echo 'FAIL: injected replacement failure accepted' >&2;exit 1
fi
[[ $(shasum -a 256 "$fixture/VoiceInk.app/Contents/MacOS/VoiceInk" | cut -d' ' -f1) == "$original" ]]
codesign --verify --deep --strict "$fixture/VoiceInk.app"
echo 'Manifest-driven signed installation and rollback passed; process query simulated, app never launched.'
