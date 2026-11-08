#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
work=$(mktemp -d /private/tmp/voiceink-resolver-test.XXXXXX)
trap 'rm -rf "$work"' EXIT
cat > "$work/xcodebuild" <<'MOCK'
#!/bin/bash
n=$(cat "$RESOLVER_TEST_COUNTER" 2>/dev/null || printf 0)
n=$((n+1)); printf '%s' "$n" > "$RESOLVER_TEST_COUNTER"
if [[ "$n" == 2 && "$RESOLVER_TEST_CASE" == transient ]]; then exit 0; fi
printf '%s\n' "$RESOLVER_TEST_ERROR"
exit 74
MOCK
cat > "$work/sleep" <<'MOCK'
#!/bin/bash
exit 0
MOCK
chmod +x "$work/xcodebuild" "$work/sleep"
export PATH="$work:$PATH" VOICEINK_DERIVED_DATA="$work/DerivedData" RESOLVER_TEST_COUNTER="$work/counter"
export RESOLVER_TEST_CASE=transient RESOLVER_TEST_ERROR='badResponseStatusCode(503)'
scripts/ci/resolve-packages.sh > "$work/log"
[[ $(cat "$work/counter") == 2 ]]
for message in 'Operation not permitted' 'badResponseStatusCode(403)' 'checksum mismatch'; do
  rm "$work/counter"
  export RESOLVER_TEST_ERROR="$message"
  if scripts/ci/resolve-packages.sh > "$work/log"; then exit 1; fi
  [[ $(cat "$work/counter") == 1 ]]
done
rm "$work/counter"
export RESOLVER_TEST_CASE=always RESOLVER_TEST_ERROR='badResponseStatusCode(503)'
if scripts/ci/resolve-packages.sh > "$work/log"; then exit 1; fi
[[ $(cat "$work/counter") == 3 ]]
printf 'Resolver retry boundaries PASS\n'
