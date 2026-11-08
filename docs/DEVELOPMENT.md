# Local development and automated releases

The stable app is `/Applications/VoiceInk.app`. Development candidates live under the checkout's ignored `.dev-build/` directory. Both use the existing bundle identifier, signing certificate and user profile. Settings changed in Dev also affect stable; there is no second profile or automatic preference rollback.

## Try a change

From this checkout, run:

```sh
task dev
```

This builds first, without disturbing the running app. It then requests an app-owned idle quit: VoiceInk waits for recording, transcription, import work and audio restoration to finish. The launcher verifies the process has exited, creates one verified rolling profile snapshot, opens the signed Dev candidate and waits for it to close. After Dev exits, it reopens stable. It never force-quits an app or replaces `/Applications/VoiceInk.app`.

Both apps show their upstream/fork version in About; Dev also shows `git describe`, including distance from the last Plus tag, abbreviated commit and a dirty marker when applicable. The bundle identifier and signing certificate stay the same, retaining permissions. Do not open another copy manually while testing Dev.

The installed r3 predates the idle-switch protocol. Close it once with Command-Q before the first test; after stable is upgraded to a protocol-aware build, subsequent `task dev` sessions switch automatically. Unsupported old copies are never guessed idle from microphone activity. The wait is bounded to twenty minutes. Interrupting or timing out the waiting launcher cancels its request; a dead requester cannot leave a deferred quit armed. Concurrent launchers are refused by a shared-profile session lock.

The only rolling Dev data backup is `~/Library/Application Support/VoiceInk-Personal-Backups/dev-latest`. A new snapshot is copied and byte-checked before replacing the previous snapshot; on failure the previous verified snapshot remains. There can briefly be a staging/previous directory during rotation. Historical release-install backups are separate. Nothing is backed up during live recording.

Use `task dev:build` to build without launching, or `scripts/dev.sh run` when Task is unavailable. Xcode, its Metal Toolchain, Python 3 and the existing local signing identity are required. A new machine can prepare the pinned macOS-only Whisper dependency with `scripts/ci/prepare-whisper.sh`. Existing unrelated dependency checkouts are preserved and cause a clear refusal if their revision differs.

## Check a branch

```sh
task check
```

GitHub Actions runs the same relevant checks and an ad-hoc-signed full app build on a standard Apple Silicon `macos-15` runner, on PRs and `main`. It uses Xcode 26.3 and installs Metal Toolchain when needed. PR builds receive no release signing secrets or write token. A manual Checks run also uploads a Dev ZIP for one day; routine PR/main checks do not retain app artifacts. These artifacts are build evidence, not replacements for the certificate-qualified stable app. Release handoff artifacts also expire after one day.

## One-time release signing setup

Signed releases require the same identity as existing installations. The `release` environment needs two encrypted Actions secrets: `VOICEINK_P12_BASE64` and `VOICEINK_P12_PASSWORD`. Neither belongs in source, workflow artifacts, logs or chat.

The owner may explicitly approve and run:

```sh
scripts/configure-ci-signing.sh --upload
```

This selects only the existing VoiceInk certificate by its fixed SHA-256, exports that identity with a random password in memory, and uses the signed-in GitHub CLI to upload the two secrets to `legrch/VoiceInk` environment `release` on github.com. macOS may request Keychain authorization. It does not export every identity, print key material or write a P12 into the checkout. Do not invoke it without the owner's explicit approval. If setup fails partway, inspect the two named secrets before another attempt; a partial pair is not a successful setup.

A runner imports the identity into a temporary keychain, verifies the fixed certificate fingerprint and removes the keychain afterward. Only release builds receive it. A manual **Release → Run workflow** on `main` is a signed packaging/install/rollback dry run and never publishes, uploads a release artifact or changes an installed app.

## Publish the next version

1. Prepare the next `release/plus.json`: retain the exact upstream version/commit, increase fork revision and allocate a build strictly greater than every published build. Generate Info/plist settings with `python3 scripts/plus-release.py sync-info`.
2. Test the Dev candidate, run checks and the required source review, and merge through a reviewed PR. Wait for the `macos-build` check on that exact `main` commit.
3. Run:

   ```sh
   task release
   ```

The command requires a clean checkout equal to `origin/main`, verifies the manifest and existing releases, refuses an existing local/remote tag, creates an annotated tag and pushes only that tag. No force push is used.

The tag triggers **Release**: validate main ancestry/tag/build ordering, run tests, build with the existing certificate, package ZIP plus `release.json` and checksums, verify installation/rollback in disposable destinations, then publish the new GitHub release. Publication rechecks the tag's commit and build ordering under a serialized publish job. It never replaces old release assets. Missing signing secrets or failed checks stop publication.

The installation command stays unchanged. Its code is pinned by commit/hash; future releases supply strictly validated JSON data, not executable installer code from mutable release metadata. The installer constructs its own repository URLs and verifies archive hash, app signature, fixed certificate, bundle/version/build/tag, updater isolation, backups and replacement rollback. The pre-CI r3 and historical exact legacy release remain installable without a new manifest. No automatic in-app updater is enabled.

Standard GitHub-hosted runners are free for public repositories; job duration, concurrency and storage limits still apply. Use short-lived CI artifacts and public release assets for durable downloads. Do not select paid larger runners.

## Qualification status

Source checks, local signed builds, PR builds, signed GitHub dry runs, publication and owner-observed app switching are separate checks. A green unsigned CI job does not qualify signing or a live microphone/music trial. Signing setup requires explicit owner authorization; the workflow is not end-to-end qualified until its signed dry run succeeds.
