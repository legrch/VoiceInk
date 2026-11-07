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
release_version=$(sed -n 's/^VERSION=//p' "$installer")
[[ -n "$release_version" ]]
bash -n "$installer"
# Only process-query responses are simulated. Bundle, checksum, certificate,
# staging, backup and rename operations use the real signed archive and files.
install_fixture() {
    bash -c 'source "$1"; pgrep() { return 1; }; shift; main "$@"' bash "$installer" "$@"
}
if bash -c 'source "$1"; pgrep() { return 0; }; main --archive "$2" --destination "$3"' bash "$installer" "$archive" "$target"; then
    echo 'FAIL: running app allowed at a custom destination' >&2; exit 1
fi
[[ ! -e "$target" ]]
install_fixture --version latest --archive "$archive" --destination "$target"
codesign --verify --deep --strict "$target"
original=$(shasum -a 256 "$target/Contents/MacOS/VoiceInk" | awk '{print $1}')
install_fixture --version "$release_version" --archive "$archive" --destination "$target"
[[ $(find "$test_root/target/VoiceInk-Personal-Backups" -name VoiceInk.app -type d | wc -l | tr -d ' ') == 1 ]]
if bash -c '
  source "$1"
  queries=0
  pgrep() { queries=$((queries + 1)); if [[ $queries -ge 3 ]]; then return 0; else return 1; fi; }
  main --archive "$2" --destination "$3"
' bash "$installer" "$archive" "$target"; then
    echo 'FAIL: app reopening during staging was ignored' >&2; exit 1
fi
[[ $(shasum -a 256 "$target/Contents/MacOS/VoiceInk" | awk '{print $1}') == "$original" ]]
# Fail only the final candidate rename; the original rename and rollback remain real.
if bash -c '
  source "$1"
  pgrep() { return 1; }
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
if install_fixture --archive "$test_root/invalid.zip" --destination "$test_root/reject/VoiceInk.app"; then
    echo 'FAIL: corrupt archive was accepted' >&2; exit 1
fi
[[ ! -e "$test_root/reject/VoiceInk.app" ]]
mkdir "$test_root/target/.voiceink-personal-install.lock"
if install_fixture --archive "$archive" --destination "$target"; then
    echo 'FAIL: existing install lock was ignored' >&2; exit 1
fi
[[ -d "$test_root/target/.voiceink-personal-install.lock" ]]
rmdir "$test_root/target/.voiceink-personal-install.lock"
echo 'PASS: simulated process checks, real signed first install, update, backup, injected failure rollback, corrupt archive and lock refusal; no app launched.'

for rejected_args in '--version unknown' '--version' '--version latest --version plus-v2.25-r1'; do
    if bash -c 'source "$1"; shift; main "$@"' bash "$installer" $rejected_args --archive "$archive" --destination "$target"; then
        echo 'FAIL: invalid version request accepted' >&2; exit 1
    fi
    [[ $(shasum -a 256 "$target/Contents/MacOS/VoiceInk" | awk '{print $1}') == "$original" ]]
done
mkdir -p "$test_root/library/Application Support/com.prakashjoshipax.VoiceInk" "$test_root/library/Application Support/VoiceInk/CustomSounds" "$test_root/library/Preferences" "$test_root/data-backup"
printf 'database fixture' > "$test_root/library/Application Support/com.prakashjoshipax.VoiceInk/store"
printf 'sound fixture' > "$test_root/library/Application Support/VoiceInk/CustomSounds/custom.wav"
printf 'preferences fixture' > "$test_root/library/Preferences/com.prakashjoshipax.VoiceInk.plist"
bash -c 'source "$1"; backup_user_data "$2" "$3"' bash "$installer" "$test_root/library" "$test_root/data-backup"
cmp "$test_root/library/Application Support/VoiceInk/CustomSounds/custom.wav" "$test_root/data-backup/CustomSounds/custom.wav"
cmp "$test_root/library/Application Support/com.prakashjoshipax.VoiceInk/store" "$test_root/data-backup/Application Support/store"
cmp "$test_root/library/Preferences/com.prakashjoshipax.VoiceInk.plist" "$test_root/data-backup/Preferences.plist"
echo 'PASS: latest/explicit-version selection, invalid-version refusal and complete Library backup fixtures.'
