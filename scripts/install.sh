#!/bin/bash
# Install the pinned VoiceInk Plus release. Never launch the app or change Gatekeeper.
set -euo pipefail
VERSION=plus-v2.25-r3
UPSTREAM_VERSION=2.25
BUILD_NUMBER=1003
ASSET=VoiceInk-Plus-2.25-r3-AppleSilicon.zip
ARCHIVE_SHA256=8199b0ffcb12cdc5042d05d92d6decf3f417859b928a1844d2c73a819b41673d
CERT_SHA256=fbb0182020b4091415f9ee73f17b156010daac2291f3f700a85ba4c5d7dbdb89
BUNDLE_ID=com.prakashjoshipax.VoiceInk

die() { echo "Error: $*" >&2; exit 1; }
# Explicit source paths keep backup tests isolated from the owner's Library.
backup_user_data() {
    local library=$1 backup=$2
    local support="$library/Application Support/$BUNDLE_ID"
    local sounds="$library/Application Support/VoiceInk/CustomSounds"
    local prefs="$library/Preferences/$BUNDLE_ID.plist"
    [[ ! -d "$support" ]] || ditto "$support" "$backup/Application Support"
    [[ ! -d "$sounds" ]] || ditto "$sounds" "$backup/CustomSounds"
    [[ ! -f "$prefs" ]] || ditto "$prefs" "$backup/Preferences.plist"
}

# Release metadata is data only. URLs and the certificate trust root stay in code.
load_release() {
    local requested=$1 manifest=${2:-} local_archive=${3:-} selected=$1
    if [[ "$selected" == latest ]]; then
        if [[ -n "$local_archive" && -z "$manifest" ]]; then selected=$VERSION
        else
            curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' --max-filesize 1048576 \
                https://api.github.com/repos/legrch/VoiceInk/releases/latest -o "$work/latest.json"
            selected=$(plutil -extract tag_name raw -o - "$work/latest.json") || die 'Invalid latest-release metadata.'
        fi
    fi
    [[ "$selected" =~ ^plus-v[0-9]+\.[0-9]+(\.[0-9]+)?-r[1-9][0-9]*$ ]] || die 'Invalid release tag.'
    # The last pre-CI release has no manifest. Its immutable archive remains pinned.
    if [[ "$selected" == "$VERSION" && -z "$manifest" ]]; then return; fi
    if [[ -z "$manifest" ]]; then
        manifest="$work/release.json"
        curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' --max-filesize 16384 \
            "https://github.com/legrch/VoiceInk/releases/download/$selected/release.json" -o "$manifest"
    fi
    [[ -f "$manifest" && $(stat -f %z "$manifest") -le 16384 ]] || die 'Invalid release manifest size.'
    local schema tag upstream revision build asset checksum
    schema=$(plutil -extract schema raw -o - "$manifest") || die 'Missing manifest schema.'
    tag=$(plutil -extract tag raw -o - "$manifest") || die 'Missing release tag.'
    upstream=$(plutil -extract upstream_version raw -o - "$manifest") || die 'Missing upstream version.'
    revision=$(plutil -extract revision raw -o - "$manifest") || die 'Missing fork revision.'
    build=$(plutil -extract build raw -o - "$manifest") || die 'Missing build.'
    asset=$(plutil -extract asset raw -o - "$manifest") || die 'Missing archive name.'
    checksum=$(plutil -extract archive_sha256 raw -o - "$manifest") || die 'Missing archive checksum.'
    [[ "$schema" == 1 && "$upstream" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ && "$revision" =~ ^[1-9][0-9]{0,8}$ ]] || die 'Invalid release identity.'
    [[ "$build" =~ ^[1-9][0-9]{2,8}$ && "$build" -gt 225 ]] || die 'Invalid release build.'
    [[ "$tag" == "$selected" && "$tag" == "plus-v$upstream-r$revision" ]] || die 'Manifest tag mismatch.'
    [[ "$asset" == "VoiceInk-Plus-$upstream-r$revision-AppleSilicon.zip" && "$checksum" =~ ^[a-f0-9]{64}$ ]] || die 'Invalid archive identity.'
    VERSION=$tag; UPSTREAM_VERSION=$upstream; BUILD_NUMBER=$build; ASSET=$asset; ARCHIVE_SHA256=$checksum
}

main() {
    destination=/Applications/VoiceInk.app
    local archive='' manifest='' replace=false requested_version=latest version_seen=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --destination) [[ $# -ge 2 ]] || die 'Missing destination'; destination=$2; shift 2 ;;
            --manifest) [[ $# -ge 2 && -z "$manifest" ]] || die 'Specify --manifest once, with a path.'; manifest=$2; shift 2 ;;
            --archive) [[ $# -ge 2 ]] || die 'Missing archive'; archive=$2; shift 2 ;;
            --version)
                [[ $# -ge 2 && "${2:-}" != --* && "$version_seen" == false ]] || die 'Specify --version once, with a value.'
                requested_version=$2; version_seen=true; shift 2 ;;
            --replace-existing) replace=true; shift ;;
            --help) echo 'Usage: bash install.sh [--version latest|plus-vVERSION-rN] [--replace-existing] [--archive /path/release.zip] [--manifest /path/release.json] [--destination /path/VoiceInk.app]'; return ;;
            *) die "Unknown argument: $1" ;;
        esac
    done
    [[ "$requested_version" == latest || "$requested_version" =~ ^plus-v[0-9]+\.[0-9]+(\.[0-9]+)?-r[1-9][0-9]*$ ]] || die "Unsupported version: $requested_version."
    [[ $(uname -s) == Darwin && $(uname -m) == arm64 ]] || die 'Requires an Apple Silicon Mac.'
    [[ $(sw_vers -productVersion | cut -d. -f1) -ge 15 ]] || die 'Requires macOS 15 or newer.'
    [[ "$destination" == /*/VoiceInk.app && "$destination" != *$'
'* && ! -L "$destination" ]] || die 'Destination must be an absolute non-symlink VoiceInk.app path.'
    local parent; parent=$(dirname "$destination")
    [[ -d "$parent" && -w "$parent" ]] || die 'Destination directory is not writable. Choose a writable --destination; do not run with sudo.'
    parent=$(cd -P "$parent" && pwd)
    destination="$parent/VoiceInk.app"
    [[ $EUID -ne 0 ]] || die 'Run as your normal user, without sudo.'
    assert_closed
    work=$(mktemp -d /private/tmp/voiceink-release-install.XXXXXXXX)
    stage=''
    locked=false
    replacing=false
    placed=false
    lock="$parent/.voiceink-personal-install.lock"
    cleanup() {
        local result=$?
        trap - EXIT INT TERM
        if [[ "$replacing" == true ]]; then
            if [[ "$placed" == true && -d "$destination" ]]; then
                mv "$destination" "$stage/failed.app" || echo "Could not move failed candidate: $destination" >&2
            fi
            if [[ -d "$stage/original.app" && ! -e "$destination" ]]; then
                mv "$stage/original.app" "$destination" || echo "Rollback needs attention: $stage/original.app" >&2
            fi
            echo "Installation failed; recovery staging preserved at $stage" >&2
        elif [[ -n "$stage" ]]; then
            rm -rf "$stage"
        fi
        [[ "$locked" != true ]] || rmdir "$lock" || true
        rm -rf "$work"
        exit "$result"
    }
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    mkdir "$lock" 2>/dev/null || die 'Another installation or a retained install lock exists. Inspect it before retrying.'
    locked=true
    load_release "$requested_version" "$manifest" "$archive"
    echo "Selected VoiceInk Plus $VERSION (requested: $requested_version)."
    if [[ -z "$archive" ]]; then
        archive="$work/$ASSET"
        curl --fail --location --proto '=https' --proto-redir '=https' --output "$archive" \
            "https://github.com/legrch/VoiceInk/releases/download/$VERSION/$ASSET"
    fi
    [[ -f "$archive" ]] || die 'Archive not found.'
    [[ $(shasum -a 256 "$archive" | awk '{print $1}') == "$ARCHIVE_SHA256" ]] || die 'Archive checksum mismatch; nothing installed.'
    ditto -x -k "$archive" "$work/unpacked"
    local candidate="$work/unpacked/VoiceInk-Plus/VoiceInk.app"
    [[ -d "$candidate" && ! -L "$candidate" ]] || die 'Expected application missing from archive.'
    codesign --verify --deep --strict "$candidate"
    if /usr/libexec/PlistBuddy -c 'Print VoiceInkDevDescription' "$candidate/Contents/Info.plist" >/dev/null 2>&1; then
        die 'Refusing to install a development build as a stable release.'
    fi
    [[ $(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$candidate/Contents/Info.plist") == "$BUNDLE_ID" ]] || die 'Unexpected bundle identifier.'
    [[ $(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$candidate/Contents/Info.plist") == "$UPSTREAM_VERSION" ]] || die 'Unexpected upstream version.'
    [[ $(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$candidate/Contents/Info.plist") == "$BUILD_NUMBER" ]] || die 'Unexpected Plus build.'
    [[ $(/usr/libexec/PlistBuddy -c 'Print VoiceInkPlusTag' "$candidate/Contents/Info.plist") == "$VERSION" ]] || die 'Unexpected Plus release tag.'
    codesign -d --extract-certificates="$work/new-cert" "$candidate" >/dev/null 2>&1
    [[ $(shasum -a 256 "$work/new-cert0" | awk '{print $1}') == "$CERT_SHA256" ]] || die 'Unexpected signing certificate.'
    if /usr/libexec/PlistBuddy -c 'Print SUFeedURL' "$candidate/Contents/Info.plist" >/dev/null 2>&1; then
        die 'Unexpected upstream update feed.'
    fi
    if [[ -e "$destination" ]]; then
        [[ -d "$destination" ]] || die 'Destination is not an application directory.'
        codesign --verify --deep --strict "$destination"
        [[ $(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$destination/Contents/Info.plist") == "$BUNDLE_ID" ]] || die 'Refusing to replace a different application.'
        codesign -d --extract-certificates="$work/old-cert" "$destination" >/dev/null 2>&1
        if ! cmp -s "$work/new-cert0" "$work/old-cert0" && [[ "$replace" != true ]]; then
            die 'Existing VoiceInk uses a different certificate. Re-run with --replace-existing to approve migration and backup.'
        fi
    fi
    local backup_root backup
    if [[ "$destination" == /Applications/VoiceInk.app ]]; then
        backup_root="$HOME/Library/Application Support/VoiceInk-Personal-Backups"
    else
        backup_root="$parent/VoiceInk-Personal-Backups"
    fi
    mkdir -p "$backup_root"
    backup=$(mktemp -d "$backup_root/release.XXXXXXXX")
    if [[ -d "$destination" ]]; then
        ditto "$destination" "$backup/VoiceInk.app"
        codesign --verify --deep --strict "$backup/VoiceInk.app"
    fi
    if [[ "$destination" == /Applications/VoiceInk.app ]]; then
        backup_user_data "$HOME/Library" "$backup"
    fi
    assert_closed
    stage=$(mktemp -d "$parent/.voiceink-release-stage.XXXXXXXX")
    ditto "$candidate" "$stage/new.app"
    codesign --verify --deep --strict "$stage/new.app"
    assert_closed
    replacing=true
    if [[ -e "$destination" ]]; then mv "$destination" "$stage/original.app"; fi
    mv "$stage/new.app" "$destination"
    placed=true
    codesign --verify --deep --strict "$destination"
    replacing=false
    printf 'Installed %s at %s\nBackup: %s\nOpen the app manually. No app was launched or data imported.\n' "$VERSION" "$destination" "$backup"
    cleanup
}
assert_closed() {
    local status=0
    pgrep -x VoiceInk >/dev/null || status=$?
    [[ $status == 1 ]] || die 'Quit VoiceInk with Command-Q before installing (or process check failed).'
}
# Sourcing permits isolated transaction tests with shell function fault injection.
# Downloading and piping to bash still runs main; no read/eval of remote metadata.
if [[ ${BASH_SOURCE[0]:-} == "$0" || -z ${BASH_SOURCE[0]:-} ]]; then main "$@"; fi
