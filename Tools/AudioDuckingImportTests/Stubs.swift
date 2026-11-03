import Foundation
import SwiftData
struct ShortcutBackup: Codable { var shortcut: String = "" }
struct CustomPrompt: Codable {}
struct ModeConfig: Codable { var id = UUID() }
struct CustomCloudModel {
    var id: UUID; var name, displayName, description, apiEndpoint, modelName: String
    var isMultilingualModel: Bool; var supportedLanguages: [String: String]
    init(id: UUID, name: String, displayName: String, description: String, apiEndpoint: String, modelName: String, isMultilingual: Bool, supportedLanguages: [String: String]) {
        self.id=id; self.name=name; self.displayName=displayName; self.description=description; self.apiEndpoint=apiEndpoint
        self.modelName=modelName; self.isMultilingualModel=isMultilingual; self.supportedLanguages=supportedLanguages
    }
}
final class APIKeyManager { static let shared=APIKeyManager(); func saveCustomModelAPIKey(_ key:String, forModelId:UUID) {} }
@MainActor final class AIEnhancementService { var customPrompts:[CustomPrompt]=[]; func repairModePromptSelections() {} }
@MainActor final class RecordingShortcutManager {
    enum ShortcutSelection: String { case custom }; enum Mode: String { case toggle }
    var primaryRecordingShortcut: ShortcutSelection = .custom; var secondaryRecordingShortcut: ShortcutSelection = .custom
    var primaryRecordingShortcutMode: Mode = .toggle; var secondaryRecordingShortcutMode: Mode = .toggle
}
@MainActor final class MenuBarManager { var isMenuBarOnly=false }
@MainActor final class RecorderUIManager { var recorderType="" }
@MainActor final class PlaybackController { var isPauseMediaEnabled=false }
@MainActor final class TranscriptionModelManager { func refreshAllAvailableModels() {} }
enum ShortcutKey { case primaryRecording, secondaryRecording, pasteLastTranscription, pasteLastEnhancement, retryLastTranscription, cancelRecorder, openQuickHistory, quickAddToDictionary, mode(UUID) }
enum ShortcutStore { static func setShortcut(_ value:String, for key:ShortcutKey) {} ; static func removeShortcutStorage(for key:ShortcutKey) {} }
@MainActor final class ModeManager { static let shared=ModeManager(); var configurations:[ModeConfig]=[]; func saveConfigurations() {} }
@MainActor final class EmojiManager { static let shared=EmojiManager(); func addCustomEmoji(_ value:String) -> Bool { true } }
@MainActor final class LaunchAtLoginManager { static let shared=LaunchAtLoginManager(); func setEnabled(_ value:Bool) {} }
enum AppAppearancePreference: String { case system; static let userDefaultsKey=""; func apply() {} }
enum AppLanguagePreference { static let userDefaultsKey=""; static func normalizedRawValue(_ value:String)->String { value }; static func apply(rawValue:String) {} }
enum CleanupSettingsKeys { static let isTranscriptionCleanupEnabled="", transcriptionRetentionMinutes="", isAudioCleanupEnabled="", audioRetentionPeriod="" }
enum FinishAndSendKey:String { case enter }
enum FinishAndSendSettings { static let key="" }
enum AutoLearnReviewSchedule:String { case day }
enum AutoLearnSettings {
    enum AIReviewMode: String { case disabled }
    static let isEnabledKey="", minimumCorrectionsKey="", aiReviewModeKey=""
    static func clampedMinimumCorrections(_ value: Int) -> Int { value }
}
enum PasteMethod: String { case standard; static func setCurrent(_ value: PasteMethod) {} }
enum SmartPunctuation { static let settingsKey="" }
actor AutoLearnService { static let shared=AutoLearnService(); func settingDidChange(isEnabled:Bool) async {}; func suggestionThresholdDidChange() async {} }
@MainActor enum DictionaryService { static func cleanUpDictionaryContent(context: ModelContext, source:String) {} }
struct DictionaryReplacementEntry { let sources:[String]; let replacement:String; let createdAt:Date? }
enum WordReplacementVariants { static func parse(_ value:String)->[String] { [] } }
struct DictionaryVocabularyEntry { let term:String; let createdAt:Date? }
struct DictionaryArchive { let vocabulary:[DictionaryVocabularyEntry]; let replacements:[DictionaryReplacementEntry] }
enum ImportMode { case merge }
struct DictionarySummary { var vocabularyToImport=0, replacementRulesToImport=0, skippedEntryCount=0 }
struct DictionaryImportResult { let summary=DictionarySummary() }
@MainActor enum DictionaryImportExportService { static func apply(archive:DictionaryArchive, mode:ImportMode, modelContext:ModelContext) async throws -> DictionaryImportResult { DictionaryImportResult() } }
@MainActor final class CustomCloudModelManager { static let shared=CustomCloudModelManager(); var customModels:[CustomCloudModel]=[]; func saveCustomModels() {} }
final class MemoryDefaults: UserDefaults {
    var values: [String: Any] = [:]
    override func object(forKey defaultName: String) -> Any? { values[defaultName] }
    override func data(forKey defaultName: String) -> Data? { values[defaultName] as? Data }
    override func bool(forKey defaultName: String) -> Bool { values[defaultName] as? Bool ?? false }
    override func set(_ value: Any?, forKey defaultName: String) { values[defaultName] = value }
}
@MainActor final class MediaController {
    let duckingSettings = AudioDuckingSettings(defaults: MemoryDefaults(suiteName: "voiceink-import-memory-only")!)
    var isSystemMuteEnabled = false
    var audioResumptionDelay: Double = 3
    var duckingConfigurationPending = false
}
