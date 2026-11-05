#!/bin/bash
# Exercise the real pinned, signed release in disposable destinations. No launch.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
archive=${1:?Usage: run.sh /absolute/path/to/pinned-release.zip}
test_root=$(mktemp -d /private/tmp/voiceink-release-tests.XXXXXXXX)
trap 'rm -rf "$test_root"' EXIT
mkdir "$test_root/target"
target="$test_root/target/VoiceInk.app"
installer="$root/scripts/install.sh"
bash -n "$installer"
bash "$installer" --archive "$archive" --destination "$target"
codesign --verify --deep --strict "$target"
original=$(shasum -a 256 "$target/Contents/MacOS/VoiceInk" | awk '{print $1}')
bash "$installer" --archive "$archive" --destination "$target"
[[ $(find "$test_root/target/VoiceInk-Personal-Backups" -name VoiceInk.app -type d | wc -l | tr -d ' ') == 1 ]]
# Fail only the final candidate rename; the original rename and rollback remain real.
if bash -c '
  source "$1"
  mv() { if [[ "$1" == */new.app ]]; then return 17; fi; command mv "$@"; }
  main --archive "$2" --destination "$3"
' bash "$installer" "$archive" "$target"; then
    echo 'FAIL: simulated rename failure was accepted' >&2; exit 1
fi
codesign --verify --deep --strict "$target"
[[ $(shasum -a 256 "$target/Contents/MacOS/VoiceInk" | awk '{print $1}') == "$original" ]]
[[ ! -d "$test_root/target/.voiceink-personal-install.lock" ]]
printf 'invalid archive' > "$test_root/invalid.zip"
mkdir "$test_root/reject"
if bash "$installer" --archive "$test_root/invalid.zip" --destination "$test_root/reject/VoiceInk.app"; then
    echo 'FAIL: corrupt archive was accepted' >&2; exit 1
fi
[[ ! -e "$test_root/reject/VoiceInk.app" ]]
mkdir "$test_root/target/.voiceink-personal-install.lock"
if bash "$installer" --archive "$archive" --destination "$target"; then
    echo 'FAIL: existing install lock was ignored' >&2; exit 1
fi
[[ -d "$test_root/target/.voiceink-personal-install.lock" ]]
rmdir "$test_root/target/.voiceink-personal-install.lock"
echo 'PASS: real signed first install, update, backup, injected failure rollback, corrupt archive and lock refusal; no app launched.'
