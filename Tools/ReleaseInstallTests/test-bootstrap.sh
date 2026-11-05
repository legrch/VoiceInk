#!/bin/bash
# Exercise bootstrap parsing, verified handoff and cleanup without installation.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
bootstrap=${VOICEINK_BOOTSTRAP_TEST_SCRIPT:-"$root/scripts/install-release.sh"}
payload="$root/scripts/install.sh"
fixture=$(mktemp -d /private/tmp/voiceink-bootstrap-tests.XXXXXXXX)
trap 'rm -rf "$fixture"' EXIT
# Historical exact-version installs retain the immutable legacy payload.
export BOOTSTRAP_LEGACY_PAYLOAD="$fixture/legacy-install.sh"
git -C "$root" show 7852619a59ba84f34e386019c55eaf8fa1ba5eeb:scripts/install.sh > "$BOOTSTRAP_LEGACY_PAYLOAD"
cat > "$fixture/runner.sh" <<'RUNNER'
#!/bin/bash
source "$1"
payload=$2
mode=$3
result=$4
shift 4
mktemp() { command mktemp "$@" | tee "$result/work"; }
curl() {
    printf '%s\n' "$@" > "$result/download"
    download_args="$*"
    output=''
    while [[ $# -gt 0 ]]; do
        if [[ "$1" == -o ]]; then output=$2; shift 2; else shift; fi
    done
    [[ -n "$output" ]]
    case "$mode" in
        download-failure) return 22 ;;
        corrupt) printf 'not the verified installer' > "$output" ;;
        *)
            if [[ "$download_args" == *7852619a59ba84f34e386019c55eaf8fa1ba5eeb* ]]; then
                cp "$BOOTSTRAP_LEGACY_PAYLOAD" "$output"
            else cp "$payload" "$output"; fi ;;
    esac
}
bash() {
    printf '%s\n' "$@" > "$result/invocation"
    [[ "$mode" != payload-failure ]] || return 17
}
install_release "$@"
RUNNER
run_case() {
    local mode=$1 name=$2; shift 2
    mkdir "$fixture/$name"
    /bin/bash "$fixture/runner.sh" "$bootstrap" "$payload" "$mode" "$fixture/$name" "$@"
}
assert_cleaned() {
    [[ -f "$fixture/$1/work" ]]
    [[ ! -e $(cat "$fixture/$1/work") ]]
}
run_case good default
sed -n '2,6p' "$fixture/default/invocation" > "$fixture/actual"
printf '%s\n' --version latest --replace-existing --destination /Applications/VoiceInk.app > "$fixture/expected"
cmp "$fixture/actual" "$fixture/expected"
assert_cleaned default
run_case good explicit personal-2.25.1 --destination "$fixture/a directory/VoiceInk.app"
sed -n '2,6p' "$fixture/explicit/invocation" > "$fixture/actual"
printf '%s\n' --version personal-2.25.1 --replace-existing --destination "$fixture/a directory/VoiceInk.app" > "$fixture/expected"
cmp "$fixture/actual" "$fixture/expected"
assert_cleaned explicit
run_case good plus plus-v2.25-r1
sed -n '2,6p' "$fixture/plus/invocation" > "$fixture/actual"
printf '%s\n' --version plus-v2.25-r1 --replace-existing --destination /Applications/VoiceInk.app > "$fixture/expected"
cmp "$fixture/actual" "$fixture/expected"
assert_cleaned plus
rg -q '7852619a59ba84f34e386019c55eaf8fa1ba5eeb' "$fixture/explicit/download"
! rg -q '7852619a59ba84f34e386019c55eaf8fa1ba5eeb' "$fixture/plus/download"
for mode in download-failure corrupt payload-failure; do
    expected=1
    [[ "$mode" != download-failure ]] || expected=22
    [[ "$mode" != payload-failure ]] || expected=17
    status=0
    run_case "$mode" "$mode" latest || status=$?
    [[ $status == "$expected" ]]
    assert_cleaned "$mode"
    if [[ "$mode" != payload-failure ]]; then [[ ! -e "$fixture/$mode/invocation" ]]; fi
done
for name in unknown empty missing-path repeated-destination unknown-flag; do
    case "$name" in
        unknown) args=(unknown) ;;
        empty) args=('') ;;
        missing-path) args=(latest --destination) ;;
        repeated-destination) args=(latest --destination /a/VoiceInk.app --destination /b/VoiceInk.app) ;;
        unknown-flag) args=(latest --archive /a/release.zip) ;;
    esac
    if run_case good "$name" "${args[@]}"; then echo "FAIL: $name accepted" >&2; exit 1; fi
    [[ ! -e "$fixture/$name/download" && ! -e "$fixture/$name/work" ]]
done
/bin/sh -n "$bootstrap"
cat "$bootstrap" | /bin/sh -s -- --help > "$fixture/help"
rg -q '^Usage:' "$fixture/help"
printf 'PASS: bootstrap default/exact version, quoting, real checksum, corrupt/download failures, child status, cleanup and stock sh pipe entry. No app installed.\n'
