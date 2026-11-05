import Foundation

/// A present but invalid payload is distinct from an absent legacy payload.
enum AudioDuckingBackupPayload {
    case absent
    case invalid
    case valid(AudioDuckingConfiguration)
}

enum AudioDuckingBackupDecision: Equatable {
    case preserve
    case apply(AudioDuckingConfiguration)
    case reject
}

enum AudioDuckingBackupPolicy {
    static func decide(
        payload: AudioDuckingBackupPayload,
        legacyMute: Bool?,
        current: AudioDuckingConfiguration
    ) -> AudioDuckingBackupDecision {
        switch payload {
        case .invalid:
            return .reject
        case .valid(let configuration):
            return configuration.isValid ? .apply(configuration) : .reject
        case .absent:
            guard let legacyMute else { return .preserve }
            var updated = current
            updated.mode = legacyMute ? .mute : .unchanged
            return .apply(updated)
        }
    }
}
