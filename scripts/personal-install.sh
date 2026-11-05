#!/bin/bash
# Explicit local installation only. Never call this from personal-update/build.
set -euo pipefail
if [[ $# != 1 || ${VOICEINK_INSTALL_APPROVED:-} != YES ]]; then
    echo 'Usage: VOICEINK_INSTALL_APPROVED=YES scripts/personal-install.sh /absolute/path/VoiceInk.app' >&2
    exit 2
fi
candidate=$1
installed=/Applications/VoiceInk.app
[[ "$candidate" == /* && -d "$candidate" && -d "$installed" && "$candidate" != "$installed" ]] || exit 2
# Refuse to replace a running app, and treat process-query errors as failures.
assert_closed() {
    local status=0
    pgrep -x VoiceInk >/dev/null || status=$?
    if [[ $status == 0 ]]; then echo 'Quit VoiceInk before installation.' >&2; exit 1; fi
    if [[ $status != 1 ]]; then echo 'Could not confirm VoiceInk is closed.' >&2; exit 1; fi
}
assert_closed
for app in "$candidate" "$installed"; do
    codesign --verify --deep --strict "$app"
    [[ $(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$app/Contents/Info.plist") == com.prakashjoshipax.VoiceInk ]]
done
if /usr/libexec/PlistBuddy -c 'Print SUFeedURL' "$candidate/Contents/Info.plist" >/dev/null 2>&1; then
    echo 'Refusing a build containing the upstream Sparkle feed.' >&2; exit 1
fi
checkdir=$(mktemp -d /private/tmp/voiceink-install-check.XXXXXX)
staging=''
replacing=false
lock=/Applications/.voiceink-personal-install.lock
locked=false
cleanup() {
    if [[ "$replacing" == true && -n "$staging" && -d "$staging/original.app" ]]; then
        if [[ -e "$installed" ]]; then
            mv "$installed" "$staging/failed.app" || echo "Could not move failed app; original remains at $staging/original.app" >&2
        fi
        if [[ ! -e "$installed" ]]; then
            mv "$staging/original.app" "$installed" || echo "Rollback failed; original remains at $staging/original.app" >&2
        fi
    fi
    [[ "$locked" != true ]] || rmdir "$lock" || true
    rm -rf "$checkdir"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
if ! mkdir "$lock" 2>/dev/null; then
    echo 'Another VoiceInk installation owns the destination lock.' >&2; exit 1
fi
locked=true
codesign -d --extract-certificates="$checkdir/old" "$installed" >/dev/null 2>&1
codesign -d --extract-certificates="$checkdir/new" "$candidate" >/dev/null 2>&1
if [[ ! -s "$checkdir/old0" || ! -s "$checkdir/new0" ]] || ! cmp -s "$checkdir/old0" "$checkdir/new0"; then
    echo 'Signing certificates differ; refusing installation.' >&2; exit 1
fi
assert_closed
backup_root="$HOME/Library/Application Support/VoiceInk-Personal-Backups"
mkdir -p "$backup_root"
backup=$(mktemp -d "$backup_root/install.XXXXXXXX")
ditto "$installed" "$backup/VoiceInk.app"
support="$HOME/Library/Application Support/com.prakashjoshipax.VoiceInk"
prefs="$HOME/Library/Preferences/com.prakashjoshipax.VoiceInk.plist"
sounds="$HOME/Library/Application Support/VoiceInk/CustomSounds"
[[ ! -d "$support" ]] || ditto "$support" "$backup/Application Support"
[[ ! -f "$prefs" ]] || ditto "$prefs" "$backup/Preferences.plist"
[[ ! -d "$sounds" ]] || ditto "$sounds" "$backup/CustomSounds"
codesign --verify --deep --strict "$backup/VoiceInk.app"
staging=$(mktemp -d /Applications/.voiceink-install.XXXXXXXX)
ditto "$candidate" "$staging/new.app"
codesign --verify --deep --strict "$staging/new.app"
# Keep the original available for rollback on an error or interruption.
assert_closed
replacing=true
mv "$installed" "$staging/original.app"
mv "$staging/new.app" "$installed"
codesign --verify --deep --strict "$installed"
# Keep a second rollback copy; failure invokes the rollback trap.
mv "$staging/original.app" "$backup/original.app"
replacing=false
rmdir "$staging"
printf 'Installed. Backup and original app: %s\n' "$backup"
