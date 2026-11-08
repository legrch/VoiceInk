#!/bin/bash
# Build a signed personal copy in a fresh temporary directory. Never install it.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
identity=${VOICEINK_SIGNING_IDENTITY:-C5C6F16ED5A3D8B28CF3A4CA19638284E9190C6B}
derived=$(mktemp -d /private/tmp/voiceink-personal-build.XXXXXX)
python3 scripts/plus-release.py check
Tools/AudioDuckingTests/run.sh
# Preserve the Xcode variable for the build system.
# shellcheck disable=SC2016
xcodebuild -project VoiceInk.xcodeproj -scheme VoiceInk -configuration Release \
    -derivedDataPath "$derived" -xcconfig LocalBuild.xcconfig \
    CODE_SIGN_IDENTITY="$identity" CODE_SIGNING_REQUIRED=YES CODE_SIGNING_ALLOWED=YES \
    DEVELOPMENT_TEAM='' CODE_SIGN_ENTITLEMENTS="$PWD/VoiceInk/VoiceInk.local.entitlements" \
    'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) LOCAL_BUILD' \
    -skipPackagePluginValidation -skipMacroValidation build
app="$derived/Build/Products/Release/VoiceInk.app"
codesign --verify --deep --strict "$app"
python3 scripts/plus-release.py check --app "$app"
[[ $(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$app/Contents/Info.plist") == com.prakashjoshipax.VoiceInk ]]
if /usr/libexec/PlistBuddy -c 'Print SUFeedURL' "$app/Contents/Info.plist" >/dev/null 2>&1; then
    echo 'Upstream Sparkle feed must be absent.' >&2; exit 1
fi
printf '\nVerified test app: %s\n' "$app"
printf 'Nothing was launched, installed or pushed.\n'
