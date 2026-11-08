# Fork releases and upstream updates

Status: owner-approved convention. The Plus metadata, About panel and installer support were implemented for `plus-v2.25-r1` (upstream 2.25, revision 1, build 1001). Automatic updates remain disabled.

## Published baseline

- Keep the published `personal-2.25.1` tag and assets unchanged. Its application reports upstream version `2.25`, build `225`.
- `latest` resolves the newest published Plus release through GitHub; the bootstrap retains a separate immutable installer pin for exact `personal-2.25.1` requests.
- The public install/update command remains the one at the top of [README](../README.md).

## VoiceInk Plus versions

Keep the full upstream version and our release revision separate. Do not reserve upstream's third version component for fork changes.

| Upstream version | Fork revision | Release title | Git tag | Example build |
|---|---|---|---|---|
| 2.25 | 1 | VoiceInk Plus 2.25 · r1 | `plus-v2.25-r1` | 1001 |
| 2.25 | 2 | VoiceInk Plus 2.25 · r2 | `plus-v2.25-r2` | 1002 |
| 2.25 | 3 | VoiceInk Plus 2.25 · r3 | `plus-v2.25-r3` | 1003 |
| 2.25.1 | 1 | VoiceInk Plus 2.25.1 · r1 | `plus-v2.25.1-r1` | 1004 |
| 2.26 | 1 | VoiceInk Plus 2.26 · r1 | `plus-v2.26-r1` | 1005 |

- Preserve the upstream version exactly as provenance, including any patch component. Increment `rN` for each published Plus release on that base; start at `r1` when the upstream version changes.
- Use an independent, strictly increasing numeric `CFBundleVersion`. Choose its initial value above the installed and published builds. The first Plus release allocates build 1001; choose a higher build for every later published release. Never reset this counter on a new upstream base or derive update order from `rN` alone.
- Tags are human-readable Git identifiers, not strict SemVer or an updater comparison algorithm. SemVer `+metadata` does not determine precedence. A future own updater must use a qualified numeric build ordering.
- Keep repository `legrch/VoiceInk`, bundle identifier, signing identity and `/Applications/VoiceInk.app`. Label Plus as an independent fork, separate from upstream's Pro product.

## Preparing a Plus release

Follow [Development and automated releases](DEVELOPMENT.md). Integrate code through a reviewed PR and request a release using `task release`, or run the **Release** workflow manually on **main** in **publish** mode. Ordinary main merges never publish.

GitHub allocates the next revision/build, reserves an annotated tag, generates effective application metadata, builds/signs, verifies installation/rollback and publishes. The command does not edit source files or create a per-release commit/PR. `release/plus.json` remains upstream provenance/local defaults; Actions stamps only the copied app. The reserved annotation and public `release.json` retain the exact released identity and source. Preserve global numeric ordering across published and failed/superseded reservations; do not recycle numbers or tags.

Existing signing protection stays in place, including its inherited administrator-bypass exception. See the development guide for dry runs, queue behavior, immutable reservation recovery and supersession. Historical tags and installer pins remain unchanged. The old `pin-installer`/`pin-bootstrap` operations are only for deliberate installer maintenance or reproducing historical releases, not routine version allocation.

The existing upstream `scripts/release.sh` assumes upstream tags and Sparkle metadata. Do not use it for Plus releases. Package/signature, runtime behavior and owner approval remain separate delivery boundaries.

## Upstream integration

`origin` is `legrch/VoiceInk`; `upstream` is `Beingpax/VoiceInk`. Our `main` contains the stable fork.

1. Start a neutral update branch from clean, current fork `main`; select and record an official upstream release and its exact commit.
2. Merge that upstream revision, retaining our audio module, narrow recording/settings seams, stable-shortcut behavior and disabled upstream updater. Resolve conflicts explicitly.
3. Run affected tests and a composed app build; validate signature, package, backup and isolated rollback. Qualify the exact candidate through the applicable source-review gate.
4. Merge through a merge commit after required checks. Preserve published history; do not rebase or force-push stable `main`.
5. Build/package the accepted source, verify its provenance, then publish the approved release and update the bootstrap pins. Verify the public download and isolated installation; qualify actual audio behavior separately.

`personal/build` is historical. `scripts/personal-update.sh` is its legacy source-rebase helper, not the stable-main update procedure or the end-user installer. Completed temporary PR branches may be removed after verifying ancestry and custody; preserve unmerged WIP and checkpoints.

## Installation and acceptance boundaries

- Automatic updates remain off. A future own update channel is a separate implementation and qualification decision.
- Preserve existing data paths, settings and output-specific levels. Do not include personal settings, credentials, models, recovery journals or machine-specific key mappings in releases.
- Install only after VoiceInk has quit; retain the old app and data backup with a rollback path. The owner authorizes verified local updates without another confirmation when the app is closed, or after a normal Quit when it is confirmed idle (no recording or transcription). Verify process exit before replacement. If activity is uncertain, defer replacement and ask the owner to finish. Never force-quit an active recording to deploy an update.
- Unit/source checks, signed build, independent review, publication, installation and owner-confirmed music trials are separate evidence. Check speakers and AirPods for audio changes; do not claim unsupported outputs work.

## References

- [SemVer metadata and precedence](https://semver.org/#spec-item-10)
- [Sparkle internal build numbers](https://sparkle-project.org/documentation/publishing/#internal-build-numbers)
