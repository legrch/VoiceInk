# Local development and automated releases

The stable app is `/Applications/VoiceInk.app`. Development candidates live under the checkout's ignored `.dev-build/` directory. Both use the existing bundle identifier, signing certificate and user profile. Settings changed in Dev also affect stable; there is no second profile or automatic preference rollback.

## Try a change

From this checkout, run:

```sh
task dev
# task d is an alias
```

This builds first, without disturbing the running app. It then requests an app-owned idle quit: VoiceInk waits for recording, transcription, import work, output delivery/clipboard cleanup and audio restoration to finish. The launcher verifies the process has exited, creates one verified rolling profile snapshot, opens the signed Dev candidate and waits for it to close. After Dev exits, it reopens stable. It never force-quits an app or replaces `/Applications/VoiceInk.app`.

Finish the work already in progress and let handover complete before starting another shortcut action. An event queued by the global shortcut worker exactly at shutdown can require another invocation. Custom commands retain their existing subprocess-cleanup contract; the launcher does not isolate detached descendants.

Both apps show their upstream/fork version in About; Dev also shows `git describe`, including distance from the last Plus tag, abbreviated commit and a dirty marker when applicable. The bundle identifier and signing certificate stay the same, retaining permissions. Do not open another copy manually while testing Dev.

The installed r3 predates the idle-switch protocol. Close it once with Command-Q before the first test; after stable is upgraded to a protocol-aware build, subsequent `task dev` sessions switch automatically. Unsupported old copies are never guessed idle from microphone activity. The wait is bounded to twenty minutes. Interrupting or timing out the waiting launcher cancels its request; a dead requester cannot leave a deferred quit armed. Concurrent launchers are refused by a shared-profile session lock.

The only rolling Dev data backup is `~/Library/Application Support/VoiceInk-Personal-Backups/dev-latest`. A new snapshot is copied and byte-checked before replacing the previous snapshot; on failure the previous verified snapshot remains. There can briefly be a staging/previous directory during rotation. Historical release-install backups are separate. Nothing is backed up during live recording.

Use `task dev:build` to build without launching, or `scripts/dev.sh run` when Task is unavailable. Xcode, its Metal Toolchain, Python 3 and the existing local signing identity are required. A new machine can prepare the pinned macOS-only Whisper dependency with `scripts/ci/prepare-whisper.sh`. Existing unrelated dependency checkouts are preserved and cause a clear refusal if their revision differs.

## Check a branch

```sh
task check
```

GitHub Actions runs the same relevant checks and an ad-hoc-signed full app build on a standard Apple Silicon `xcode-27` runner, on PRs and `main`. It uses Xcode 27.0 (Swift 6.3, required by the pinned MLX package) and installs Metal Toolchain when needed. PR builds receive no release signing secrets or write token. A manual Checks run also uploads a Dev ZIP for one day; routine PR/main checks do not retain app artifacts. These artifacts are build evidence, not replacements for the certificate-qualified stable app. Release handoff artifacts also expire after one day.

## One-time release signing setup

Signed releases require the same identity as existing installations. The `release` environment needs two encrypted Actions secrets: `VOICEINK_P12_BASE64` and `VOICEINK_P12_PASSWORD`. Neither belongs in source, workflow artifacts, logs or chat.

The owner may explicitly approve and run:

```sh
scripts/configure-ci-signing.sh --upload
```

The helper first creates a release environment requiring approval by legrch, or verifies those protections on an existing environment without replacing its rules. GitHub must confirm this policy before any key export. Each signed run requires the owner to approve its exact ref in Actions; no unreviewed branch receives the key merely by dispatching a workflow.

This selects only the existing VoiceInk certificate by its fixed SHA-256, exports that identity with a random password in memory, and uses the signed-in GitHub CLI to upload the two secrets to `legrch/VoiceInk` environment `release` on github.com. macOS may request Keychain authorization. It does not export every identity, print key material or write a P12 into the checkout. Do not invoke it without the owner's explicit approval. If setup fails partway, inspect the two named secrets before another attempt; a partial pair is not a successful setup.

The final app is re-signed with hardened runtime explicitly enabled, and the final CodeDirectory flags are checked before packaging. Existing release environments are matched case-insensitively and their protection rules are preserved.

Package resolution runs before key import, stays pinned to Package.resolved and retries only a known transient connection or HTTP 502/503/504 error (at most three attempts). Permission/auth/checksum failures are not retried. A runner imports the identity into a temporary keychain, verifies the fixed certificate fingerprint and removes the keychain afterward. Only release builds receive it. A manual **Release → Run workflow** on `main` is a signed packaging/install/rollback dry run and never publishes, uploads a release artifact or changes an installed app.

## Publish on explicit request

Ordinary commits and PR merges to `main` do not publish anything. After integrating a tested/reviewed change, request a release with:

```sh
task release
```

This command only reads the fixed fork's GitHub `main` identity and dispatches **Release** in `publish` mode, with that exact expected SHA. It prints the original Actions run URL and exits. It does not edit files, create local commits/tags, push to main, or wait on your Mac. You can instead select **Actions > Release > Run workflow**, branch **main**, mode **publish**. A successful dispatch means requested, not published; follow the linked run.

GitHub checks that the selected source has a successful completed main **Checks** run, including its macOS job. It waits up to one hour for a still-running check, but fails on a failed/canceled check, API error or source mismatch. It then computes the next `rN` on that upstream version and a globally increasing numeric build, considering published and previously reserved identities. A new upstream version starts at `r1`; its numeric build does not reset.

The read-only plan job passes validated metadata to a narrow tag-writing job. The latter creates an annotated immutable tag with version/build/source and originating run identity. The current workflow continues directly to the existing protected signing/build/package/install/rollback/publish jobs. It does not rely on a second workflow starting from its own token's tag push. No new PAT, GitHub App credential, production agent or local daemon is needed.

### Metadata and reproducibility

`release/plus.json` and generated source plist/project fields remain **upstream provenance and local-build defaults**. They do not need a new commit for each release. Change upstream provenance through a reviewed source PR when updating the upstream base.

Actions supplies `VOICEINK_RELEASE_METADATA` as validated JSON from the same run's plan and verifies it against the reserved tag and exact checkout. Only the copied app's main plist is stamped before final signing. The tracked manifest, source plist/project, helpers, entitlements, bundle ID and updater policy remain unchanged. Packaging generates the public `release.json`, archive hash and source identity from this effective metadata. The annotated tag preserves the metadata needed to reproduce that release from its exact source; archived pre-automation tags retain their original procedure.

### Approval, queue and recovery

The `release` environment retains its reviewer rule for `legrch`. GitHub repository administrators also retain the existing administrator-bypass capability; this change does not modify environment protections. A pending or rejected approval does not mean the release succeeded.

Publish workflows share one non-cancelling concurrency group. GitHub keeps one active and one pending request; a newer publish request may replace the pending one. Dry runs use a different per-run group and cannot displace publishing. This is a single-owner latest-pending-request policy, not a FIFO queue. Inspect the original run URL. A first attempt canceled before allocation has no new tag; a canceled queued **rerun** can still have a reservation from its earlier attempt and must reconcile it normally.

Rerun the original workflow to reuse its existing source/tag/build after a confirmed transient failure. No mutation is automatically retried after an uncertain response. If signing or release-only checks expose a defect requiring a different source, merge the correction through a reviewed PR and explicitly request another release. Once the original run is confirmed terminal failed/canceled and no partial release exists, the new reservation records its superseded predecessor and permanently consumes both its revision and build numbers. The old tag/evidence stays; late attempts to publish it are refused. API errors, unresolved origins, conflicting tags and draft/partial releases stop for inspection rather than moving tags or replacing assets.

Immediately before publication, the workflow revalidates exact tag-object/source/metadata, supersession and build ordering. Old assets are never clobbered. Do not delete or move a reserved tag to make a check pass.

### Safe dry run

```sh
task release:dry-run
```

Or manually run **Release**, mode **dry-run** (the default). It computes candidate metadata, builds/signs/packages and verifies disposable installation/rollback without reserving a tag, publishing or uploading release assets. A branch may be selected for a trusted candidate dry run; it still goes through the signing environment. A publishing request must select `main`. Source review, fake tests, PR CI, a protected signed dry run and actual publication remain separate evidence.

The user installation command stays unchanged. Its code is pinned by commit/hash; releases supply validated JSON data, not executable installer code from mutable metadata. No automatic in-app updater is enabled.

## Qualification status

Source checks, local signed builds, PR builds, signed GitHub dry runs, publication and owner-observed app switching are separate checks. A green unsigned CI job does not qualify signing or a live microphone/music trial. Signing setup requires explicit owner authorization; new workflow changes are not end-to-end qualified until their signed dry run succeeds. Historical successful runs do not qualify later candidates.
