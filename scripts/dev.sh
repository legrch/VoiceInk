#!/bin/bash
# Explicit dev launch only; stable application and its data are never replaced.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
case ${1:-help} in
  build|run)
    action=$1
    build_root=$(mktemp -d "$PWD/.dev-build/candidate.XXXXXXXX" 2>/dev/null) || {
      mkdir -p "$PWD/.dev-build"; build_root=$(mktemp -d "$PWD/.dev-build/candidate.XXXXXXXX");
    }
    if [[ "$action" == run ]]; then
      python3 scripts/dev-session.py --build "$build_root/VoiceInk.app"
    else
      VOICEINK_BUILD_OUTPUT="$build_root" scripts/build-app.sh dev
      printf 'Development app: %s/VoiceInk.app\n' "$build_root"
    fi ;;
  *) echo 'Usage: scripts/dev.sh build|run (same permissions/data, close the other copy before run)' ;;
esac
