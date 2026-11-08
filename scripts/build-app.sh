#!/bin/bash
# Shared app build. Never install, launch, publish or export signing material.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
mode=${1:-dev}
[[ "$mode" == dev || "$mode" == release || "$mode" == ci ]] || { echo 'Usage: scripts/build-app.sh dev|release|ci' >&2; exit 2; }
identity=${VOICEINK_SIGNING_IDENTITY:-VoiceInk Local}
[[ "$mode" != ci ]] || identity=-
[[ "$mode" != release || "$identity" != - ]] || { echo 'Release requires the existing signing identity.' >&2; exit 1; }
derived=${VOICEINK_DERIVED_DATA:-"$PWD/.dev-build/DerivedData"}
output=${VOICEINK_BUILD_OUTPUT:-"$PWD/.dev-build/output"}
[[ "$derived" == /* && "$output" == /* && "$output" != / && "$output" != /Applications* && "$output" != "$HOME" ]] || exit 2
if [[ "$mode" == release && -n $(git status --porcelain) ]]; then
  echo 'Release builds require a clean committed checkout; use dev for local edits.' >&2; exit 1
fi
python3 scripts/plus-release.py check
source_commit=$(git rev-parse HEAD)
[[ -d "$HOME/VoiceInk-Dependencies/whisper.cpp/build-apple/whisper.xcframework" ]] || { echo 'Run scripts/ci/prepare-whisper.sh first.' >&2; exit 1; }
xcodebuild -project VoiceInk.xcodeproj -scheme VoiceInk -configuration Release \
  -derivedDataPath "$derived" -xcconfig LocalBuild.xcconfig \
  CODE_SIGN_IDENTITY="$identity" CODE_SIGNING_REQUIRED=YES CODE_SIGNING_ALLOWED=YES DEVELOPMENT_TEAM='' \
  CODE_SIGN_ENTITLEMENTS="$PWD/VoiceInk/VoiceInk.local.entitlements" \
  'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) LOCAL_BUILD' \
  -onlyUsePackageVersionsFromResolvedFile -skipPackagePluginValidation -skipMacroValidation build
mkdir -p "$output"
[[ ! -e "$output/VoiceInk.app" ]] || { echo 'Build output already exists; choose a fresh VOICEINK_BUILD_OUTPUT.' >&2; exit 1; }
ditto "$derived/Build/Products/Release/VoiceInk.app" "$output/VoiceInk.app"
[[ $(git rev-parse HEAD) == "$source_commit" ]] || { echo 'Source HEAD changed during the build; rebuild the intended candidate.' >&2; exit 1; }
if [[ "$mode" == release && -n $(git status --porcelain) ]]; then
  echo 'Release source changed during the build; refusing to package it.' >&2; exit 1
fi
description=$(git describe --tags --match 'plus-v*' --long --always --dirty)
python3 scripts/stamp-build.py "$output/VoiceInk.app" "$mode" "$source_commit" "$description"
codesign --force --sign "$identity" --entitlements VoiceInk/VoiceInk.local.entitlements "$output/VoiceInk.app"
codesign --verify --deep --strict "$output/VoiceInk.app"
python3 scripts/plus-release.py check --app "$output/VoiceInk.app"
printf 'Verified app: %s\n' "$output/VoiceInk.app"
