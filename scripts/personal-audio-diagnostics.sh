#!/bin/bash
# Local read-only report; output includes the audio device UID.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
tmp=$(mktemp -d /private/tmp/voiceink-audio-observe.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
base=VoiceInk/PersonalFeatures/AudioDucking
swiftc -parse-as-library "$base/AudioDuckingConfiguration.swift" "$base/AudioDuckingLease.swift" \
    "$base/AudioDuckingControlOwnership.swift" "$base/AudioDuckingRuntime.swift" \
    "$base/AudioDuckingRecoveryJournal.swift" "$base/AudioDuckingCoreAudio.swift" \
    Tools/AudioDuckingTests/inspect-recovery-readonly.swift -o "$tmp/observe"
"$tmp/observe"
