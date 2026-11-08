#!/bin/bash
# GitHub-hosted macOS provisioning only; never changes the owner's local tools.
set -euo pipefail
[[ ${GITHUB_ACTIONS:-} == true && ${RUNNER_OS:-} == macOS ]] || { echo 'This helper is only for the macOS CI runner.' >&2; exit 2; }
for package in cmake gh; do
  if ! command -v "$package" >/dev/null; then brew install "$package"; fi
done
command -v python3 >/dev/null
sudo xcode-select -s /Applications/Xcode_27.app/Contents/Developer
xcodebuild -version
xcodebuild -downloadComponent MetalToolchain
cmake --version
gh --version
python3 --version
