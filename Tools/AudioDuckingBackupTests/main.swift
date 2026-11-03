import Foundation

// Minimal unrelated application models; GeneralBackup and BackupFile are the
// production definitions, not reconstructed test equivalents.
struct ShortcutBackup: Codable {}
struct CustomPrompt: Codable {}
struct ModeConfig: Codable {}
struct CustomCloudModel {
    var id: UUID
    var name, displayName, description, apiEndpoint, modelName: String
    var isMultilingualModel: Bool
    var supportedLanguages: [String: String]
    init(id: UUID, name: String, displayName: String, description: String, apiEndpoint: String,
         modelName: String, isMultilingual: Bool, supportedLanguages: [String: String]) {
        self.id = id; self.name = name; self.displayName = displayName; self.description = description
        self.apiEndpoint = apiEndpoint; self.modelName = modelName; self.isMultilingualModel = isMultilingual
        self.supportedLanguages = supportedLanguages
    }
}
final class APIKeyManager {
    static let shared = APIKeyManager()
    func saveCustomModelAPIKey(_ key: String, forModelId id: UUID) {}
}
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
}
func decode(_ general: String) throws -> BackupFile {
    let json = "{\"version\":\"1\",\"generalSettings\":\(general)}"
    return try JSONDecoder().decode(BackupFile.self, from: Data(json.utf8))
}
let legacy = try decode("{\"isSystemMuteEnabled\":true}")
if case .absent = legacy.generalSettings!.audioDucking {} else { check(false, "legacy payload absent") }
for payload in ["null", "42", "{\"version\":99,\"mode\":\"duck\"}"] {
    let backup = try decode("{\"audioDucking\":\(payload),\"isSystemMuteEnabled\":true}")
    if case .invalid = backup.generalSettings!.audioDucking {} else { check(false, "invalid payload retained") }
}
let valid = try decode("{\"audioDucking\":{\"version\":1,\"mode\":\"duck\",\"retainedPercent\":30,\"fadeDownSeconds\":1.5,\"fadeUpSeconds\":1,\"restoreDelaySeconds\":0},\"isSystemMuteEnabled\":true}")
if case .valid(let settings) = valid.generalSettings!.audioDucking {
    check(settings.mode == .duck && settings.retainedPercent == 30, "production backup decoder")
} else { check(false, "valid production payload") }
let encoded = try JSONEncoder().encode(valid)
let restored = try JSONDecoder().decode(BackupFile.self, from: encoded)
if case .valid(let settings) = restored.generalSettings!.audioDucking { check(settings.retainedPercent == 30, "production backup round trip") }
else { check(false, "round trip payload") }
print("Production backup JSON decoder and encoder checks passed")

let exportedGeneral = GeneralBackup(
    primaryRecordingShortcut: nil, secondaryRecordingShortcut: nil,
    pasteLastTranscriptionShortcut: nil, pasteLastEnhancementShortcut: nil,
    retryLastTranscriptionShortcut: nil, cancelRecorderShortcut: nil,
    openHistoryWindowShortcut: nil, quickAddToDictionaryShortcut: nil,
    primaryRecordingShortcutRawValue: nil, secondaryRecordingShortcutRawValue: nil,
    primaryRecordingShortcutModeRawValue: nil, secondaryRecordingShortcutModeRawValue: nil,
    launchAtLoginEnabled: nil, isMenuBarOnly: nil, recorderType: nil,
    appAppearancePreference: nil, appLanguagePreference: nil,
    isTranscriptionCleanupEnabled: nil, transcriptionRetentionMinutes: nil,
    isAudioCleanupEnabled: nil, audioRetentionPeriod: nil,
    isSystemMuteEnabled: false, isPauseMediaEnabled: nil, audioResumptionDelay: nil,
    audioDucking: .valid(AudioDuckingConfiguration(mode: .duck)),
    isTextFormattingEnabled: nil, isExperimentalFeaturesEnabled: nil,
    restoreClipboardAfterPaste: nil, clipboardRestoreDelay: nil, pasteMethod: nil,
    smartPunctuationEnabled: nil, finishAndSendKey: nil,
    isAutoLearnDictionaryEnabled: nil, autoLearnMinimumCorrections: nil, autoLearnAIReviewMode: nil
)
let exportedBytes = try JSONEncoder().encode(exportedGeneral)
let exportedRoundTrip = try JSONDecoder().decode(GeneralBackup.self, from: exportedBytes)
if case .valid(let value) = exportedRoundTrip.audioDucking { check(value.mode == .duck, "production memberwise export") }
else { check(false, "production memberwise export round trip") }
