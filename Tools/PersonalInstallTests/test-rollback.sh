#!/bin/bash
# Test the install transaction in a disposable tree, never /Applications.
set -euo pipefail
root=$(mktemp -d /private/tmp/voiceink-install-test.XXXXXX)
trap 'rm -rf "$root"' EXIT
mkdir -p "$root/applications/VoiceInk.app" "$root/candidate/VoiceInk.app" "$root/bin"
printf 'original\n' > "$root/applications/VoiceInk.app/marker"
printf 'candidate\n' > "$root/candidate/VoiceInk.app/marker"
mkdir "$root/fixture-sounds"
printf 'custom-sound' > "$root/fixture-sounds/custom.wav"
cat > "$root/bin/pgrep" <<'SH'
#!/bin/bash
if [[ ${VOICEINK_TEST_REOPEN:-0} == 1 ]]; then
    count=0
    [[ ! -f "$VOICEINK_TEST_ROOT/process-count" ]] || count=$(cat "$VOICEINK_TEST_ROOT/process-count")
    count=$((count + 1))
    printf '%s' "$count" > "$VOICEINK_TEST_ROOT/process-count"
    [[ $count -lt 2 ]] || exit 0
fi
exit 1
SH
cat > "$root/bin/ditto" <<'SH'
#!/bin/bash
cp -a "$1" "$2"
SH
cat > "$root/bin/plistbuddy" <<'SH'
#!/bin/bash
if [[ "$2" == 'Print CFBundleIdentifier' ]]; then printf 'com.prakashjoshipax.VoiceInk\n'; exit 0; fi
exit 1
SH
cat > "$root/bin/codesign" <<'SH'
#!/bin/bash
for arg in "$@"; do
    case "$arg" in --extract-certificates=*) prefix=${arg#*=}; printf 'same-certificate' > "${prefix}0"; exit 0 ;; esac
done
app=${!#}
if [[ ${VOICEINK_TEST_FAIL_INSTALLED:-} == 1 && "$app" == "$VOICEINK_TEST_ROOT/applications/VoiceInk.app" && -f "$app/marker" && $(cat "$app/marker") == candidate ]]; then exit 1; fi
exit 0
SH
chmod +x "$root/bin/"*
python3 - "$root" <<'PY'
from pathlib import Path
import sys
root=Path(sys.argv[1]); text=Path('scripts/personal-install.sh').read_text()
text=text.replace('/Applications', str(root/'applications'))
text=text.replace('/usr/libexec/PlistBuddy', str(root/'bin/plistbuddy'))
text=text.replace('backup_root="$HOME/Library/Application Support/VoiceInk-Personal-Backups"', 'backup_root="$VOICEINK_TEST_ROOT/backups"')
text=text.replace('support="$HOME/Library/Application Support/com.prakashjoshipax.VoiceInk"', 'support="$VOICEINK_TEST_ROOT/absent-support"')
text=text.replace('prefs="$HOME/Library/Preferences/com.prakashjoshipax.VoiceInk.plist"', 'prefs="$VOICEINK_TEST_ROOT/absent-prefs"')
text=text.replace('sounds="$HOME/Library/Application Support/VoiceInk/CustomSounds"', 'sounds="$VOICEINK_TEST_ROOT/fixture-sounds"')
assert '/Applications' not in text and '$HOME/Library' not in text
(root/'install-test.sh').write_text(text)
PY
export PATH="$root/bin:$PATH" VOICEINK_TEST_ROOT="$root" VOICEINK_TEST_FAIL_INSTALLED=1 VOICEINK_INSTALL_APPROVED=YES
if bash "$root/install-test.sh" "$root/candidate/VoiceInk.app" >"$root/output" 2>&1; then
    echo 'FAIL: injected signature error did not stop installation' >&2; exit 1
fi
[[ $(cat "$root/applications/VoiceInk.app/marker") == original ]] || { echo 'FAIL: original was not restored' >&2; exit 1; }
[[ $(find "$root/backups" -name marker -type f -exec cat {} \;) == *original* ]] || { echo 'FAIL: backup missing' >&2; exit 1; }
printf 'Isolated installation error restores the original and retains a backup.\n'

[[ $(find "$root/backups" -name custom.wav -type f -exec cat {} \;) == custom-sound ]] || { echo 'FAIL: custom sounds missing' >&2; exit 1; }
export VOICEINK_TEST_REOPEN=1
if bash "$root/install-test.sh" "$root/candidate/VoiceInk.app" >"$root/reopen-output" 2>&1; then
    echo 'FAIL: reopened VoiceInk was ignored' >&2; exit 1
fi
grep -q 'Quit VoiceInk before installation' "$root/reopen-output"
[[ $(cat "$root/applications/VoiceInk.app/marker") == original ]]
printf 'CustomSounds backup and reopening-before-backup refusal passed.\n'

unset VOICEINK_TEST_REOPEN
mkdir "$root/applications/.voiceink-personal-install.lock"
if bash "$root/install-test.sh" "$root/candidate/VoiceInk.app" >"$root/local-lock-output" 2>&1; then
    echo 'FAIL: local installer ignored transaction lock' >&2; exit 1
fi
grep -q 'destination lock' "$root/local-lock-output"
if bash -c 'source "$1"; pgrep() { return 1; }; main --destination "$2" --archive "$3"' bash "$PWD/scripts/install.sh" "$root/applications/VoiceInk.app" "$root/unused.zip" >"$root/release-lock-output" 2>&1; then
    echo 'FAIL: release installer ignored local transaction lock' >&2; exit 1
fi
grep -q 'retained install lock' "$root/release-lock-output"
[[ -d "$root/applications/.voiceink-personal-install.lock" && $(cat "$root/applications/VoiceInk.app/marker") == original ]]
rmdir "$root/applications/.voiceink-personal-install.lock"
printf 'Both installers refuse the same held destination lock without mutation.\n'
