#!/bin/bash
# Import only the owner-provided identity into an ephemeral runner keychain.
set -euo pipefail
[[ ${GITHUB_ACTIONS:-} == true && ${RUNNER_OS:-} == macOS && -n ${RUNNER_TEMP:-} ]] || exit 2
keychain="$RUNNER_TEMP/voiceink-signing.keychain-db"
if [[ ${1:-} == cleanup ]]; then
  security delete-keychain "$keychain" >/dev/null 2>&1 || true
  rm -f "$RUNNER_TEMP/voiceink-signing.p12" "$RUNNER_TEMP/voiceink-signing.pem"
  exit 0
fi
[[ -n ${VOICEINK_P12_BASE64:-} && -n ${VOICEINK_P12_PASSWORD:-} ]] || { echo 'Configure VOICEINK_P12_BASE64 and VOICEINK_P12_PASSWORD GitHub secrets first.' >&2; exit 1; }
umask 077
printf '%s' "$VOICEINK_P12_BASE64" | base64 --decode > "$RUNNER_TEMP/voiceink-signing.p12"
password=$(openssl rand -hex 32)
security create-keychain -p "$password" "$keychain"
security set-keychain-settings -lut 21600 "$keychain"
security unlock-keychain -p "$password" "$keychain"
security import "$RUNNER_TEMP/voiceink-signing.p12" -P "$VOICEINK_P12_PASSWORD" -k "$keychain" -T /usr/bin/codesign -T /usr/bin/security
security find-certificate -c "VoiceInk Local" -p "$keychain" > "$RUNNER_TEMP/voiceink-signing.pem"
fingerprint=$(openssl x509 -in "$RUNNER_TEMP/voiceink-signing.pem" -noout -fingerprint -sha256 | cut -d= -f2 | tr -d ':' | tr 'A-F' 'a-f')
[[ "$fingerprint" == fbb0182020b4091415f9ee73f17b156010daac2291f3f700a85ba4c5d7dbdb89 ]] || { echo 'Signing certificate differs from the installer trust root.' >&2; exit 1; }
sudo security add-trusted-cert -d -r trustRoot -k "$keychain" "$RUNNER_TEMP/voiceink-signing.pem"
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$password" "$keychain" >/dev/null
security list-keychains -d user -s "$keychain"
rm -f "$RUNNER_TEMP/voiceink-signing.p12" "$RUNNER_TEMP/voiceink-signing.pem"
