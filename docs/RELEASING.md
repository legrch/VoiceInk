# Fork releases and upstream updates

Status: owner-approved convention, recorded 2026-11-05. The Plus naming scheme is for future releases; its build metadata and installer support are not implemented yet.

## Published baseline

- Keep the published `personal-2.25.1` tag and assets unchanged. Its application reports upstream version `2.25`, build `225`.
- The current installer still selects `personal-2.25.1`. Recording a future tag convention does not change `latest` or enable automatic updates.
- The public install/update command remains the one at the top of [README](../README.md).

## Future VoiceInk Plus versions

Keep the full upstream version and our release revision separate. Do not reserve upstream's third version component for fork changes.

| Upstream version | Fork revision | Release title | Git tag | Example build |
|---|---|---|---|---|
| 2.25 | 1 | VoiceInk Plus 2.25 · r1 | `plus-v2.25-r1` | 1001 |
| 2.25 | 2 | VoiceInk Plus 2.25 · r2 | `plus-v2.25-r2` | 1002 |
| 2.25.1 | 1 | VoiceInk Plus 2.25.1 · r1 | `plus-v2.25.1-r1` | 1003 |
| 2.26 | 1 | VoiceInk Plus 2.26 · r1 | `plus-v2.26-r1` | 1004 |

- Preserve the upstream version exactly as provenance, including any patch component. Increment `rN` for each published Plus release on that base; start at `r1` when the upstream version changes.
- Use an independent, strictly increasing numeric `CFBundleVersion`. Choose its initial value above the installed and published builds; 1001 is an example, not an allocated build. Never reset this counter on a new upstream base or derive update order from `rN` alone.
- Tags are human-readable Git identifiers, not strict SemVer or an updater comparison algorithm. SemVer `+metadata` does not determine precedence. A future own updater must use a qualified numeric build ordering.
- Keep repository `legrch/VoiceInk`, bundle identifier, signing identity and `/Applications/VoiceInk.app`. Label Plus as an independent fork, separate from upstream's Pro product.

## First Plus release prerequisite

Implement and verify the metadata layer before publishing the first Plus artifact:

1. Keep upstream version/commit, Plus revision and numeric build in one release metadata source; derive package names and tags from it.
2. Show upstream version and Plus revision separately in About/diagnostics. Apply build metadata to the main app only; do not globally override XPC or test-target versions.
3. Extend the installer version whitelist and payload pins for the new release. Update immutable installer/checksum and archive/certificate checks consistently; preserve the legacy exact-version installation path.
4. Publish a new immutable artifact after the normal checks and source review. Never relabel or overwrite the old release's app bytes to implement branding.

The existing upstream `scripts/release.sh` assumes `v$SHORT_VERSION` and generates Sparkle metadata. It is not a ready Plus release path. The existing source build helper does not implement the proposed metadata layer either.

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
- Install only after VoiceInk has quit; retain the old app and data backup with a rollback path. Never force-quit an active recording to deploy an update.
- Unit/source checks, signed build, independent review, publication, installation and owner-confirmed music trials are separate evidence. Check speakers and AirPods for audio changes; do not claim unsupported outputs work.

## References

- [SemVer metadata and precedence](https://semver.org/#spec-item-10)
- [Sparkle internal build numbers](https://sparkle-project.org/documentation/publishing/#internal-build-numbers)
