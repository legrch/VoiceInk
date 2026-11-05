#!/bin/sh
# One-command entrypoint. The owner selects this repository as the bootstrap trust root.
# Application replacement stays in the immutable, checksum-verified installer.
set -eu
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH
umask 077

bootstrap_fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }
bootstrap_usage() {
    printf '%s\n' 'Usage: install-release.sh [latest|plus-v2.25-r1|personal-2.25.1] [--destination /path/VoiceInk.app]'
}
install_release() {
    selected=${1-latest}
    [ "$#" -eq 0 ] || shift
    case "$selected" in
        --help|-h) [ "$#" -eq 0 ] || bootstrap_fail 'Unexpected arguments'; bootstrap_usage; return ;;
        latest|plus-v2.25-r1|personal-2.25.1) ;;
        *) bootstrap_fail 'Unknown version. Use latest, plus-v2.25-r1 or personal-2.25.1.' ;;
    esac
    destination=/Applications/VoiceInk.app
    destination_seen=false
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --destination)
                [ "$#" -ge 2 ] && [ "$destination_seen" = false ] || bootstrap_fail 'Specify --destination once, with a path.'
                destination=$2; destination_seen=true; shift 2 ;;
            *) bootstrap_fail "Unknown argument: $1" ;;
        esac
    done
    # The underlying installer validates platform, destination, processes and bundle.
    # Updating these two pins is an explicit, reviewed release operation.
    plus_installer_url=https://raw.githubusercontent.com/legrch/VoiceInk/73706d248a8f42490608cbe4b667d538324a0429/scripts/install.sh
    plus_installer_sha256=dd588da1b88aae79304c10c1d0184efbb0c87e307f18dd795f5fff51005f25ea
    case "$selected" in
        personal-2.25.1)
            installer_url=https://raw.githubusercontent.com/legrch/VoiceInk/7852619a59ba84f34e386019c55eaf8fa1ba5eeb/scripts/install.sh
            installer_sha256=79c58536608561c4b0c22a99f93f1a65e87aace155837b6287cca394556a2751 ;;
        *) installer_url=$plus_installer_url; installer_sha256=$plus_installer_sha256 ;;
    esac
    bootstrap_work=$(mktemp -d /private/tmp/voiceink-bootstrap.XXXXXXXX)
    trap 'rm -rf "$bootstrap_work"' 0
    trap 'exit 130' INT
    trap 'exit 143' TERM
    curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
        "$installer_url" -o "$bootstrap_work/install.sh"
    printf '%s  %s\n' "$installer_sha256" "$bootstrap_work/install.sh" | shasum -a 256 -c - >/dev/null || \
        bootstrap_fail 'Installer checksum mismatch; nothing installed.'
    bash "$bootstrap_work/install.sh" --version "$selected" --replace-existing --destination "$destination"
}
# This also runs when piped into the stock macOS sh. Bash sourcing is for fixtures.
if [ "${BASH_SOURCE:-$0}" = "$0" ]; then install_release "$@"; fi
