#!/bin/bash
# Exercise the real signed test bundle against a disposable install location.
set -euo pipefail
candidate=${1:?pass the absolute path to the signed test app}
[[ "$candidate" == /private/tmp/* && -d "$candidate" ]]
root=$(mktemp -d /private/tmp/voiceink-real-rollback.XXXXXX)
trap 'rm -rf "$root"' EXIT
mkdir -p "$root/applications" "$root/bin"
ditto "$candidate" "$root/applications/VoiceInk.app"
before=$(shasum -a 256 "$root/applications/VoiceInk.app/Contents/MacOS/VoiceInk" | cut -d' ' -f1)
cat > "$root/bin/pgrep" <<'SH'
#!/bin/bash
exit 1
SH
cat > "$root/bin/codesign" <<'SH'
#!/bin/bash
app=${!#}
if [[ "$1" == --verify && "$app" == "$VOICEINK_TEST_ROOT/applications/VoiceInk.app" ]]; then
    countfile="$VOICEINK_TEST_ROOT/count"
    if [[ -f "$countfile" ]]; then exit 1; fi
    : > "$countfile"
fi
exec /usr/bin/codesign "$@"
SH
chmod +x "$root/bin/"*
python3 - "$root" <<'PY'
from pathlib import Path
import sys
root=Path(sys.argv[1]); text=Path('scripts/personal-install.sh').read_text()
text=text.replace('/Applications', str(root/'applications'))
text=text.replace('backup_root="$HOME/Library/Application Support/VoiceInk-Personal-Backups"', 'backup_root="$VOICEINK_TEST_ROOT/backups"')
text=text.replace('support="$HOME/Library/Application Support/com.prakashjoshipax.VoiceInk"', 'support="$VOICEINK_TEST_ROOT/absent-support"')
text=text.replace('prefs="$HOME/Library/Preferences/com.prakashjoshipax.VoiceInk.plist"', 'prefs="$VOICEINK_TEST_ROOT/absent-prefs"')
text=text.replace('sounds="$HOME/Library/Application Support/VoiceInk/CustomSounds"', 'sounds="$VOICEINK_TEST_ROOT/absent-sounds"')
assert '/Applications' not in text and '$HOME/Library' not in text
(root/'install-test.sh').write_text(text)
PY
export PATH="$root/bin:$PATH" VOICEINK_TEST_ROOT="$root" VOICEINK_INSTALL_APPROVED=YES
if bash "$root/install-test.sh" "$candidate" >"$root/output" 2>&1; then
    echo 'FAIL: injected verification failure was ignored' >&2; exit 1
fi
after=$(shasum -a 256 "$root/applications/VoiceInk.app/Contents/MacOS/VoiceInk" | cut -d' ' -f1)
[[ "$before" == "$after" ]] || { echo 'FAIL: original executable was not restored' >&2; exit 1; }
/usr/bin/codesign --verify --deep --strict "$root/applications/VoiceInk.app"
[[ -d "$root/backups" ]] || { echo 'FAIL: backup missing' >&2; exit 1; }
printf 'Real signed bundle restored after injected installation failure.\n'
