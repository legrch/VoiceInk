# VoiceInk Personal

A personal fork of [Beingpax/VoiceInk](https://github.com/Beingpax/VoiceInk), with smooth audio ducking during dictation, per-output background levels and restoration of the original volume. The first personal release is based on the owner-tested `78cdb94d7c8875687124421adc667c9dbbd8de2b` application, with an explicit recovery-reset fix found during release review.

**[Download the ready-to-use application](https://github.com/legrch/VoiceInk/releases/latest)** · Apple Silicon (M1 or later) · macOS 15+

## Install

No Xcode, Git, patches or signing certificate are needed to install a release.

1. Download the application ZIP from Releases and extract it.
2. Quit any existing VoiceInk with **Command-Q**. Keep a copy of the old app and export its settings before replacing it manually.
3. Move `VoiceInk.app` into **Applications**, then open that copy.
4. This release is locally signed, **not Apple-notarized**. If macOS cannot verify the developer, approve only this trusted copy in **System Settings > Privacy & Security > Open Anyway**. See [Apple's instructions](https://support.apple.com/en-gb/102445). The installer does not disable Gatekeeper or remove quarantine attributes.
5. Complete first-run setup: microphone/Accessibility permissions, a transcription model or your own provider settings, and your preferred recording shortcut.

### Optional terminal installer

The installer downloads the pinned release, checks its SHA-256 and signing certificate, makes a backup, and installs without launching. It supports first installation and upgrades. Download it before executing:

```bash
voiceink_installer=$(mktemp /tmp/voiceink-personal-install.XXXXXXXX)
curl --fail --location --proto '=https' --proto-redir '=https' \
  https://github.com/legrch/VoiceInk/releases/download/personal-2.25.1/install.sh \
  -o "$voiceink_installer" &&
bash "$voiceink_installer"
```

If replacing an official or differently signed VoiceInk, explicitly approve the migration with `bash "$voiceink_installer" --replace-existing`. macOS may ask for permissions again. Do not use sudo. An unwritable Applications directory can be avoided with `--destination "$HOME/Applications/VoiceInk.app"` after creating that directory; custom destinations keep app-only backups beside the app.

Default-location backups are under `~/Library/Application Support/VoiceInk-Personal-Backups/release.*`, including the previous app (when present), application support and preferences. Failed replacement attempts restore the original app or preserve the exact recovery staging path. For a manual rollback, quit VoiceInk, move the new app aside and copy the backed-up `VoiceInk.app` into Applications. Normal installation does not modify user data; retain the data backup if a later app launch migrates it.

## Set up audio ducking

In **Audio > Audio Ducking**, enable **Lower Audio While Recording**. Turn off **Pause Media While Recording** and **Mute Audio While Recording** to keep music playing. Set **Volume During Recording** and **Fade Duration**. Levels are remembered per output device. **Current Volume** is read-only; **Volume Before Recording** captures the original level. Test a short dictation with music before relying on a new audio device. Outputs without volume controls are unsupported.

The package does not include anyone's settings, API keys, transcription models or machine-specific Karabiner mappings. Choose your own shortcut in VoiceInk. Automatic updates are disabled; install subsequent personal releases explicitly. Intel builds are not provided in this release.

If ducking pauses after an interruption, first set a comfortable system volume, then turn **Lower Audio While Recording** off and on. This explicitly archives the current output's recovery evidence and enables a fresh session without changing volume or claiming an old write was confirmed/cancelled. A live pending write, unavailable output or unreadable evidence keeps the reset blocked.

## Upstream 2.25 compatibility notes

This fork retains these known upstream behaviors: vocabulary correction applies when terms are configured even if an older opt-out preference exists; website modes match host/path and query- or fragment-specific rules may need adjustment; after importing older Soniox modes, restart before using or editing them; very large Auto-Learn AI-review backlogs can stall and may require manual dictionary review. These optional-feature limits do not change the personal audio-ducking settings.

## Fork development

- `main` is the stable personal fork; use feature branches and reviewed `--no-ff` merge commits (no squash or rebase merges).
- `upstream` points to `Beingpax/VoiceInk`; `origin` points to `legrch/VoiceInk`.
- Bring an upstream release into an update branch based on our `main` with a merge, resolve conflicts, run tests/build, then review and merge. Preserve published history; do not rebase or force-push `main`.
- `personal/build` retains the original implementation history. `scripts/personal-update.sh` is a legacy **source rebase** helper for that branch, not an end-user updater; it is not the update procedure for stable main.
- `Tools/AudioDuckingTests/run.sh` runs the audio checks. `scripts/personal-build.sh` builds from source using Xcode and a local signing identity (`VOICEINK_SIGNING_IDENTITY`); it never publishes or installs. The old `personal-install.sh` is a machine-local replacement helper requiring an existing matching certificate. For downloaded releases use `scripts/install.sh`.
- The application source and bundled licenses remain available under GPL v3; upstream attribution is retained below. No background update service or release automation is installed.

## Original VoiceInk project

<div align="center">
  <img src="VoiceInk/Assets.xcassets/AppIcon.appiconset/256-mac.png" width="180" height="180" />
  <h1>VoiceInk</h1>
  <p>Voice to text app for macOS to transcribe what you say to text almost instantly</p>

  [![License](https://img.shields.io/badge/License-GPL%20v3-blue.svg)](https://www.gnu.org/licenses/gpl-3.0)
  ![Platform](https://img.shields.io/badge/platform-macOS%2015.0%2B-brightgreen)
  [![GitHub release (latest by date)](https://img.shields.io/github/v/release/Beingpax/VoiceInk)](https://github.com/Beingpax/VoiceInk/releases)
  ![GitHub all releases](https://img.shields.io/github/downloads/Beingpax/VoiceInk/total)
  ![GitHub stars](https://img.shields.io/github/stars/Beingpax/VoiceInk?style=social)
  <p>
    <a href="https://tryvoiceink.com">Website</a> •
    <a href="https://www.youtube.com/@tryvoiceink">YouTube</a>
  </p>

  <a href="https://tryvoiceink.com">
    <img src="https://img.shields.io/badge/Download%20Now-Latest%20Version-blue?style=for-the-badge&logo=apple" alt="Download VoiceInk" width="250"/>
  </a>
</div>

---

VoiceInk is a native macOS application that transcribes what you say to text almost instantly. You can find all the information and download the app from [here](https://tryvoiceink.com). 

![VoiceInk Mac App](https://github.com/user-attachments/assets/12367379-83e7-48a6-b52c-4488a6a04bba)

After dedicating the past 5 months to developing this app, I've decided to open source it for the greater good. 

My goal is to make it **the most efficient and privacy-focused voice-to-text solution for macOS** that is a joy to use. While the source code is now open for experienced developers to build and contribute, purchasing a license helps support continued development and gives you access to automatic updates, priority support, and upcoming features.

## Features

- 🎙️ **Accurate Transcription**: Local AI models that transcribe your voice to text with 99% accuracy, almost instantly
- 🔒 **Privacy First**: 100% offline processing ensures your data never leaves your device
- ⚡ **Modes**: Intelligent app detection automatically applies your perfect pre-configured settings based on the app/ URL you're on
- 🧠 **Context Aware**: Smart AI that understands your screen content and adapts to the context
- 🎯 **Global Shortcuts**: Configurable keyboard or mouse shortcuts for quick recording and push-to-talk functionality
- 📝 **Personal Dictionary**: Train the AI to understand your unique terminology with custom words, industry terms, and smart text replacements
- 🔄 **Smart Modes**: Instantly switch between AI-powered modes optimized for different writing styles and contexts
- 🤖 **AI Assistant**: Built-in voice assistant mode for a quick chatGPT like conversational assistant

## Get Started

### Download
Get the latest version with a free trial from [tryvoiceink.com](https://tryvoiceink.com). Your purchase helps me work on VoiceInk full-time and continuously improve it with new features and updates.

#### Homebrew
Alternatively, you can install VoiceInk via `brew`:

```shell
brew install --cask voiceink
```

### Build from Source
As an open-source project, you can build VoiceInk yourself by following the instructions in [BUILDING.md](BUILDING.md). However, the compiled version includes additional benefits like automatic updates, priority support via Discord and email, and helps fund ongoing development.

## Requirements

- macOS 15.0 or later

## Documentation

- [Building from Source](BUILDING.md) - Detailed instructions for building the project
- [Contributing Guidelines](CONTRIBUTING.md) - How to contribute to VoiceInk
- [Code of Conduct](CODE_OF_CONDUCT.md) - Our community standards

## Contributing

This project is **not accepting pull requests** at this time. You're welcome to fork and modify VoiceInk for your own use.

You can still contribute by:
- Reporting bugs via [issues](https://github.com/Beingpax/VoiceInk/issues)
- Suggesting features or enhancements
- Improving documentation via issues

For more details, see our [Contributing Guidelines](CONTRIBUTING.md). For build instructions, see our [Building Guide](BUILDING.md).

## License

This project is licensed under the GNU General Public License v3.0 - see the [LICENSE](LICENSE) file for details.

## Support

If you encounter any issues or have questions, please:
1. Check the existing issues in the GitHub repository
2. Create a new issue if your problem isn't already reported
3. Provide as much detail as possible about your environment and the problem

## Acknowledgments

### Core Technology
- [whisper.cpp](https://github.com/ggerganov/whisper.cpp) - High-performance inference of OpenAI's Whisper model
- [FluidAudio](https://github.com/FluidInference/FluidAudio) - Used for Parakeet model implementation
- [TranscribeCpp for Swift](https://github.com/Beingpax/Transcribe-cpp-swift) - SwiftPM distribution of [transcribe.cpp](https://github.com/handy-computer/transcribe.cpp), used for local GGUF transcription models
- [SenseVoice Small](https://huggingface.co/FunAudioLLM/SenseVoiceSmall) by FunAudioLLM / Alibaba - Multilingual model available under the [FunASR Model Open Source License Agreement](https://github.com/modelscope/FunASR/blob/main/MODEL_LICENSE)

### Essential Dependencies
- [Sparkle](https://github.com/sparkle-project/Sparkle) - Keeping VoiceInk up to date
- [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) - User-customizable keyboard shortcuts
- [LaunchAtLogin](https://github.com/sindresorhus/LaunchAtLogin) - Launch at login functionality
- [MediaRemoteAdapter](https://github.com/ejbills/mediaremote-adapter) - Media playback control during recording
- [Zip](https://github.com/marmelroy/Zip) - File compression and decompression utilities
- [Swift Atomics](https://github.com/apple/swift-atomics) - Low-level atomic operations for thread-safe concurrent programming


---

Made with ❤️ by Pax
