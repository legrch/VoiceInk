# VoiceInk Plus

<img src="VoiceInk/Assets.xcassets/AppIcon.appiconset/256-mac.png" alt="VoiceInk" width="96" align="right" />

Voice dictation for macOS, with smooth background-audio ducking. Music gets quieter while you speak and returns to its original volume when recording stops.

**[Download the app](https://github.com/legrch/VoiceInk/releases/latest)** · **Apple Silicon** · **macOS 15+**

- Smooth fade down and back up, without waiting for transcription.
- Background volume remembered separately for speakers and headphones.
- First installation and updates through the same command below.

## Install or update

Quit VoiceInk, then paste this one command into Terminal:

```sh
curl -fsSL https://raw.githubusercontent.com/legrch/VoiceInk/main/scripts/install-release.sh | sh -s -- latest
```

The same command handles first installation and updates. It verifies the pinned installer, release archive and app signature, backs up an existing app and its data, and installs to `/Applications/VoiceInk.app` with rollback on replacement failure. Then open **VoiceInk** from Applications. No Xcode, Git, patches, signing certificate or sudo is needed.

This command trusts the bootstrap script maintained in this fork's `main`; it checks the immutable installation payload before executing it. `latest` selects the newest published Plus release (currently **2.25 · r3**, build `1003`). The installer code remains pinned; future releases provide validated release metadata, so the command stays the same. To select this release explicitly, replace `latest` with `plus-v2.25-r3`. The historical `personal-2.25.1` remains available by its exact name.

**Apple Silicon (M1 or later), macOS 15+.** This build is locally signed, **not Apple-notarized**. If macOS asks, approve this trusted copy in **System Settings > Privacy & Security > Open Anyway** ([Apple's instructions](https://support.apple.com/en-gb/102445)). First launch uses VoiceInk's normal microphone/Accessibility and model/provider setup. The installer never changes Gatekeeper or creates a personal profile on your behalf.

Backups are under `~/Library/Application Support/VoiceInk-Personal-Backups/release.*`: the previous app, application support, custom recording sounds and preferences. For rollback, quit VoiceInk, move the new app aside and copy the backed-up `VoiceInk.app` into Applications. Installation leaves user data in place; retain the data backup if a later launch migrates it.

For a custom destination, add `--destination "$HOME/Applications/VoiceInk.app"` after `latest` (create that directory first); custom destinations retain app-only backups beside the app. Keep VoiceInk closed until installation finishes. The command permits replacement of an existing signed VoiceInk and always preserves a backup.

You can also [download the ZIP](https://github.com/legrch/VoiceInk/releases/latest), extract it, and move `VoiceInk.app` into Applications after quitting and preserving your previous copy. For a fully pinned installation command with the bootstrap verified before execution, see the [existing release instructions](https://github.com/legrch/VoiceInk/releases/tag/personal-2.25.1).

## Development and releases

Use **`task dev`** for a signed local Dev candidate with the same profile, one rolling backup and an idle-aware switch back to stable. Use **`task release`** from reviewed, green `main` to push the manifest tag and start GitHub Actions. See [the development guide](docs/DEVELOPMENT.md) for the one-time signing setup and the initial r3 compatibility step. CI/release automation is not fully qualified until its signed GitHub dry run passes.

## Set up audio ducking

In **Audio > Audio Ducking**, enable **Lower Audio While Recording**. Turn off **Pause Media While Recording** and **Mute Audio While Recording** to keep music playing. Set **Volume During Recording** and **Fade Duration**. Levels are remembered per output device. **Current Volume** is read-only; **Volume Before Recording** captures the original level. Test a short dictation with music before relying on a new audio device. Outputs without volume controls are unsupported.

The installer does not create a profile or launch the app. VoiceInk creates its own profile during first launch; macOS permissions and model/provider selection use the normal setup screens.

The package does not include anyone's settings, API keys, transcription models or machine-specific Karabiner mappings. Choose your own shortcut in VoiceInk. Automatic updates are disabled; install subsequent personal releases explicitly. Intel builds are not provided in this release.

If an audio change fails, the recording remains available. After capture stops, the app archives the failed cycle, cancels its timers/listeners and prepares a new cycle from the actual current volume. Switching **Lower Audio While Recording** off/on also retries idle recovery. Device-specific percentages and fade settings are preserved; a restart or a Reset button is not part of normal recovery.

Automatic idle recovery prioritizes availability. It does not prove that an old macOS request completed or was cancelled, so a delayed hardware effect can still arrive. Recovery itself never writes a guessed baseline. Invalid/unreadable evidence or unavailable hardware defers audio effects rather than interfering with recording. Diagnostic failure files retain the original record and the first observed before/target/readback values; `scripts/personal-audio-diagnostics.sh` reads them without changing audio.

## Upstream 2.25 compatibility notes

This fork retains these known upstream behaviors: vocabulary correction applies when terms are configured even if an older opt-out preference exists; website modes match host/path and query- or fragment-specific rules may need adjustment; after importing older Soniox modes, restart before using or editing them; very large Auto-Learn AI-review backlogs can stall and may require manual dictionary review. These optional-feature limits do not change the personal audio-ducking settings.

Canceling a batch transcription can leave recording temporarily unavailable until the provider request finishes or times out. The recording guard retains shared cleanup ownership during that drain. Import audio settings while idle after volume has returned; an import during recording can display the new retained level before the runtime adopts it.

## Fork development

Maintainers: read [release/version conventions and the upstream update procedure](docs/RELEASING.md) before preparing a release. **VoiceInk Plus** preserves the upstream version and adds a separate revision such as `plus-v2.25-r3`; the existing `personal-2.25.1` release remains unchanged.

- `main` is the stable personal fork; use feature branches and reviewed `--no-ff` merge commits (no squash or rebase merges).
- `upstream` points to `Beingpax/VoiceInk`; `origin` points to `legrch/VoiceInk`.
- Bring an upstream release into an update branch based on our `main` with a merge, resolve conflicts, run tests/build, then review and merge. Preserve published history; do not rebase or force-push `main`.
- `personal/build` retains the original implementation history. `scripts/personal-update.sh` is a legacy **source rebase** helper for that branch, not an end-user updater; it is not the update procedure for stable main.
- `Tools/AudioDuckingTests/run.sh` runs the audio checks. `scripts/personal-build.sh` builds from source using Xcode and a local signing identity (`VOICEINK_SIGNING_IDENTITY`); it never publishes or installs. The old `personal-install.sh` is a machine-local replacement helper requiring an existing matching certificate. For downloaded releases use `scripts/install-release.sh`; `scripts/install.sh` is its immutable installation payload.
- The application source and bundled licenses remain available under GPL v3; upstream attribution is retained below. No background update service or release automation is installed.

## Version and release notifications

Open **VoiceInk > About VoiceInk Plus** to see the installed upstream version, Plus revision, build and release tag. **Latest Release** opens this fork's newest published release. For notifications, open [the repository](https://github.com/legrch/VoiceInk), choose **Watch > Custom > Releases**, and save ([GitHub's guide](https://docs.github.com/en/subscriptions-and-notifications/get-started/configuring-notifications)).

Updates are manual: quit VoiceInk and run the same install command again. The app does not download updates in the background or use the upstream Sparkle feed.

## Credits and license

This fork is based on [Beingpax/VoiceInk](https://github.com/Beingpax/VoiceInk). The original project provides the dictation engine and application; this fork adds the audio-ducking module and its release installer. Source and bundled dependency licenses remain available in this repository under [GPL v3](LICENSE). For the original app and its release channel, visit the [upstream project](https://github.com/Beingpax/VoiceInk).
