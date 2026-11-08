#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
for script in scripts/build-app.sh scripts/dev.sh scripts/configure-ci-signing.sh scripts/install.sh scripts/install-release.sh scripts/ci/*.sh; do bash -n "$script"; done
PYTHONDONTWRITEBYTECODE=1 python3 -m py_compile scripts/dev-backup.py scripts/dev-session.py scripts/ci/validate-tag.py scripts/ci/publish-release.py
python3 Tools/AutomationTests/test-stamp.py
python3 Tools/AutomationTests/test-build-signing.py
python3 Tools/AutomationTests/test-publish.py
python3 Tools/AutomationTests/test-session.py
Tools/AutomationTests/test-resolver.sh
work=$(mktemp -d /private/tmp/voiceink-automation-checks.XXXXXX)
trap 'rm -rf "$work"' EXIT
cp Tools/AutomationTests/gate.swift "$work/main.swift"
swiftc VoiceInk/PersonalFeatures/Release/DevSwitchGate.swift "$work/main.swift" -o "$work/gate"
"$work/gate"
swiftc Tools/DevSwitch/main.swift -o "$work/notify"
swiftc Tools/CISigning/EnvironmentPolicy.swift Tools/CISigning/main.swift -o "$work/signing"
"$work/signing" --help
cp Tools/AutomationTests/signing-policy.swift "$work/main.swift"
swiftc Tools/CISigning/EnvironmentPolicy.swift "$work/main.swift" -o "$work/signing-policy"
"$work/signing-policy"
python3 Tools/AutomationTests/test-backup.py
Tools/AutomationTests/test-manifest.sh
