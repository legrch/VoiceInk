#!/bin/sh
set -eu
repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$repo_root"
test_dir=$(mktemp -d /private/tmp/voiceink-ducking-tests.XXXXXX)
trap 'rm -rf "$test_dir"' EXIT
module_dir=/private/tmp/voiceink-swift-module-cache
base=VoiceInk/PersonalFeatures/AudioDucking
swiftc "$base/AudioDuckingConfiguration.swift" "$base/AudioDuckingLease.swift" \
    "$base/AudioDuckingBackupPolicy.swift" "$base/AudioDuckingBackupField.swift" \
    "$base/AudioDuckingControlOwnership.swift" "$base/AudioDuckingRuntime.swift" "$base/AudioDuckingRecoveryJournal.swift" "$base/AudioDuckingRecoveryCoordinator.swift" \
    "$base/AudioDuckingEventLatch.swift" "$base/AudioDelay.swift" \
    Tools/AudioDuckingTests/main.swift -o "$test_dir/pure"
"$test_dir/pure"
swiftc "$base/AudioDuckingConfiguration.swift" "$base/AudioDuckingLease.swift" \
    "$base/AudioDuckingControlOwnership.swift" "$base/AudioDuckingRuntime.swift" \
    "$base/AudioDuckingRecoveryJournal.swift" Tools/AudioDuckingRecoveryTests/main.swift -o "$test_dir/recovery"
"$test_dir/recovery"
swiftc "$base/AudioDuckingConfiguration.swift" "$base/AudioDuckingBackupPolicy.swift" \
    "$base/AudioDuckingBackupField.swift" VoiceInk/Features/Settings/Backup/BackupTypes.swift \
    Tools/AudioDuckingBackupTests/main.swift -o "$test_dir/backup"
"$test_dir/backup"
swiftc -module-cache-path "$module_dir" "$base/AudioDuckingConfiguration.swift" \
    "$base/AudioDuckingSettings.swift" Tools/AudioDuckingSettingsTests/main.swift -o "$test_dir/settings"
"$test_dir/settings"
swiftc -module-cache-path "$module_dir" -parse-as-library Tools/AudioDuckingImportTests/Stubs.swift \
    Tools/AudioDuckingImportTests/Run.swift "$base/AudioDuckingConfiguration.swift" \
    "$base/AudioDuckingBackupPolicy.swift" "$base/AudioDuckingBackupField.swift" \
    "$base/AudioDuckingSettings.swift" "$base/AudioDelay.swift" \
    VoiceInk/Features/Settings/Backup/BackupTypes.swift VoiceInk/Features/Settings/Backup/BackupImporter.swift \
    -o "$test_dir/import"
"$test_dir/import"
