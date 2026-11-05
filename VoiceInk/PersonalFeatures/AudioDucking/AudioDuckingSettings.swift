import Combine
import Foundation

/// Desired settings are persisted independently from the settings captured by an
/// active output lease. The runtime decides when a desired change takes effect.
@MainActor
final class AudioDuckingSettings: ObservableObject {
    static let storageKey = "personal.audioDucking.configuration.v1"
    private let defaults: UserDefaults

    @Published private(set) var configuration: AudioDuckingConfiguration
    @Published private(set) var invalidStoredConfiguration: Bool

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey) {
            if let decoded = try? JSONDecoder().decode(AudioDuckingConfiguration.self, from: data), decoded.isValid {
                var unified = decoded
                unified.fadeUpSeconds = unified.fadeDownSeconds
                configuration = unified
                if unified.fadeUpSeconds != decoded.fadeUpSeconds, let encoded = try? JSONEncoder().encode(unified) {
                    defaults.set(encoded, forKey: Self.storageKey)
                }
                invalidStoredConfiguration = false
            } else {
                configuration = AudioDuckingConfiguration(mode: .unchanged)
                invalidStoredConfiguration = true
            }
        } else {
            let invalid = defaults.object(forKey: Self.storageKey) != nil
            invalidStoredConfiguration = invalid
            configuration = invalid
                ? AudioDuckingConfiguration(mode: .unchanged)
                : .migrated(legacyMute: defaults.bool(forKey: "isSystemMuteEnabled"))
        }
    }

    /// Invalid data leaves both the in-memory and persisted configuration intact.
    @discardableResult
    func set(_ value: AudioDuckingConfiguration) -> Bool {
        guard value.isValid else { return false }
        var unified = value
        unified.fadeUpSeconds = unified.fadeDownSeconds
        guard let data = try? JSONEncoder().encode(unified) else { return false }
        defaults.set(data, forKey: Self.storageKey)
        configuration = unified
        invalidStoredConfiguration = false
        return true
    }
}
