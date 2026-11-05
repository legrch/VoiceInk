import Foundation
import SwiftData

@main struct Main {
    @MainActor static func main() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Schema([]), configurations: [config])
        let context = ModelContext(container)
        let media = MediaController()
        let playback = PlaybackController()
        let enhancement = AIEnhancementService()
        let shortcuts = RecordingShortcutManager()
        let menu = MenuBarManager()
        let recorder = RecorderUIManager()
        let models = TranscriptionModelManager()
        func decode(_ general: String) throws -> BackupFile {
            try JSONDecoder().decode(BackupFile.self, from: Data("{\"version\":\"1\",\"generalSettings\":\(general)}".utf8))
        }
        func apply(_ backup: BackupFile) async throws -> BackupImporter.Result {
            try await BackupImporter.apply(backup, categories: [.general], enhancementService: enhancement,
                recordingShortcutManager: shortcuts, menuBarManager: menu, mediaController: media,
                playbackController: playback, recorderUIManager: recorder, modelContext: context,
                transcriptionModelManager: models)
        }
        let valid = try decode("{\"isSystemMuteEnabled\":true,\"audioDucking\":{\"version\":1,\"mode\":\"duck\",\"retainedPercent\":30,\"fadeDownSeconds\":1.5,\"fadeUpSeconds\":1,\"restoreDelaySeconds\":0}}")
        let validResult = try await apply(valid)
        guard media.duckingSettings.configuration.mode == .duck, !media.isSystemMuteEnabled,
              validResult.rejectedAudioSettings.isEmpty else { fatalError("valid payload precedence") }
        let rejected = try decode("{\"isSystemMuteEnabled\":true,\"audioDucking\":null,\"audioResumptionDelay\":1e20}")
        let rejectedResult = try await apply(rejected)
        guard media.duckingSettings.configuration.mode == .duck, !media.isSystemMuteEnabled,
              media.audioResumptionDelay == 3, rejectedResult.rejectedAudioSettings.count == 2 else { fatalError("invalid payload precedence or delay") }
        let old = try decode("{\"isSystemMuteEnabled\":false}")
        _ = try await apply(old)
        guard media.duckingSettings.configuration.mode == .unchanged else { fatalError("legacy mode mapping") }
        print("Production backup importer precedence and delay checks passed")
    }
}
