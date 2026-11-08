#!/bin/bash
# Resolve before importing signing material. Retry only known transient reads.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
[[ -n ${VOICEINK_DERIVED_DATA:-} && "$VOICEINK_DERIVED_DATA" == /* ]] || exit 2
work=$(mktemp -d /private/tmp/voiceink-package-resolution.XXXXXX)
trap 'rm -rf "$work"' EXIT
for attempt in 1 2 3; do
  result=0
  xcodebuild -resolvePackageDependencies -project VoiceInk.xcodeproj -scheme VoiceInk -configuration Release \
    -derivedDataPath "$VOICEINK_DERIVED_DATA" -xcconfig LocalBuild.xcconfig CODE_SIGNING_ALLOWED=NO \
    -onlyUsePackageVersionsFromResolvedFile -skipPackagePluginValidation -skipMacroValidation > "$work/attempt-$attempt.log" 2>&1 || result=$?
  cat "$work/attempt-$attempt.log"
  [[ $result != 0 ]] || exit 0
  if [[ $attempt == 3 ]] || ! grep -Eq 'Could not connect to the server\.|badResponseStatusCode\((502|503|504)\)' "$work/attempt-$attempt.log" || \
    grep -Eiq 'permission denied|operation not permitted|authentication failed|checksum.*(mismatch|does not match)|(HTTP|status)[^0-9]*40[13]' "$work/attempt-$attempt.log"; then exit "$result"; fi
  printf 'Package resolution attempt %s ended on a transient network/server failure; retrying the same pinned resolution.\n' "$attempt"
  sleep 2
done
