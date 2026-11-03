#!/bin/bash
# Rebase the personal changes onto the latest upstream; never install or push.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
if [[ $(git branch --show-current) != personal/build ]]; then
    echo 'Switch to personal/build before updating.' >&2; exit 1
fi
if [[ -n $(git status --porcelain) ]]; then
    echo 'Commit or preserve all local changes before updating.' >&2; exit 1
fi
case $(git remote get-url upstream) in
    git@github.com:Beingpax/VoiceInk.git|https://github.com/Beingpax/VoiceInk.git) ;;
    *) echo 'Unexpected upstream remote; verify it before updating.' >&2; exit 1 ;;
esac
old_head=$(git rev-parse HEAD)
old_base=$(git merge-base HEAD upstream/main)
git config --local rerere.enabled true
git fetch upstream main
git rebase refs/remotes/upstream/main
new_base=$(git merge-base HEAD upstream/main)
printf '\nChanges in the personal patch after rebase:\n'
git range-diff "$old_base..$old_head" "$new_base..HEAD"
printf '\nRunning audio ducking checks:\n'
Tools/AudioDuckingTests/run.sh
printf '\nUpdate complete. Review the diff and build before installation. Nothing was pushed or installed.\n'
