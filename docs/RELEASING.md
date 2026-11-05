# Fork releases and upstream updates

Status: owner-approved convention. The Plus metadata, About panel and installer support were implemented for `plus-v2.25-r1` (upstream 2.25, revision 1, build 1001). Automatic updates remain disabled.

## Published baseline

- Keep the published `personal-2.25.1` tag and assets unchanged. Its application reports upstream version `2.25`, build `225`.
- `latest` selects `plus-v2.25-r1`; the bootstrap retains a separate immutable installer pin for exact `personal-2.25.1` requests.
- The public install/update command remains the one at the top of [README](../README.md).

## VoiceInk Plus versions

Keep the full upstream version and our release revision separate. Do not reserve upstream's third version component for fork changes.

| Upstream version | Fork revision | Release title | Git tag | Example build |
|---|---|---|---|---|
| 2.25 | 1 | VoiceInk Plus 2.25 · r1 | `plus-v2.25-r1` | 1001 |
| 2.25 | 2 | VoiceInk Plus 2.25 · r2 | `plus-v2.25-r2` | 1002 |
| 2.25.1 | 1 | VoiceInk Plus 2.25.1 · r1 | `plus-v2.25.1-r1` | 1003 |
| 2.26 | 1 | VoiceInk Plus 2.26 · r1 | `plus-v2.26-r1` | 1004 |

- Preserve the upstream version exactly as provenance, including any patch component. Increment `rN` for each published Plus release on that base; start at `r1` when the upstream version changes.
- Use an independent, strictly increasing numeric `CFBundleVersion`. Choose its initial value above the installed and published builds. The first Plus release allocates build 1001; choose a higher build for every later published release. Never reset this counter on a new upstream base or derive update order from `rN` alone.
- Tags are human-readable Git identifiers, not strict SemVer or an updater comparison algorithm. SemVer `+metadata` does not determine precedence. A future own updater must use a qualified numeric build ordering.
- Keep repository `legrch/VoiceInk`, bundle identifier, signing identity and `/Applications/VoiceInk.app`. Label Plus as an independent fork, separate from upstream's Pro product.

## Preparing a Plus release

`release/plus.json` is the release identity source: exact upstream version/commit, fork revision and independent build. The main app's version and Plus keys in `VoiceInk/Info.plist` are generated from it; helper targets keep their own version/build. About and diagnostics read those signed bundle keys. Keep the application filename, bundle ID, signing certificate and installation path unchanged.

1. Edit `release/plus.json`, incrementing the numeric build for every published release, then run `python3 scripts/plus-release.py sync-info` and `Tools/PlusReleaseTests/run.sh`.
2. Run audio checks and a signed Release build with `LOCAL_BUILD` and `LocalBuild.xcconfig`. `scripts/personal-build.sh` validates metadata before and after building, without installation. For an established reusable DerivedData lane, keep the same arguments and call `python3 scripts/plus-release.py check --app /path/VoiceInk.app` after build.
3. Package once into a fresh directory: `python3 scripts/plus-release.py package --app /path/VoiceInk.app --output /private/tmp/plus-assets`. It derives the tag/asset name, checks the bundle/signature and includes GPL/source pointers. It refuses to overwrite an archive.
4. Run `python3 scripts/plus-release.py pin-installer --archive /private/tmp/plus-assets/VoiceInk-Plus-2.25-r1-AppleSilicon.zip`. Commit the installer and app changes, then run `python3 scripts/plus-release.py pin-bootstrap --commit FULL_INSTALLER_COMMIT` and commit the bootstrap. The immutable installer pins archive bytes; the bootstrap pins installer bytes and retains the legacy exact-version route.
5. Run audio/metadata/bootstrap tests, real signed archive install/update/rollback fixtures and a composed build. Freeze the complete candidate, close the risk-selected review and merge through a reviewed merge commit with required checks green.
6. Copy the committed `scripts/install.sh` into the release assets as `install.sh`; generate `SHA256SUMS` for it and the app archive. Publish the derived tag/title on the accepted source; keep old tags/assets immutable. Verify downloaded assets and the public one-command bootstrap in an isolated destination before announcing availability. App identity changes require a fresh signed build and new archive/pins.

The installer validates archive hash, app signature/certificate, bundle ID, upstream version, build, Plus tag and updater isolation before replacement. It does not configure accounts, grant permissions, launch the app or install audio drivers. New-release alerts use GitHub's Releases watch subscription; the in-app link opens the public latest-release page.

The existing upstream `scripts/release.sh` assumes `v$SHORT_VERSION` and generates Sparkle metadata. Do not use it for Plus releases.

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
