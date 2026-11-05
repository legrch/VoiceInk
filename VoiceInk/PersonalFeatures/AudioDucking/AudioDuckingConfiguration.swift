import Foundation

/// Persisted independently of the legacy mute and playback preferences.
struct AudioDuckingConfiguration: Codable, Equatable {
    enum Mode: String, Codable, CaseIterable {
        case unchanged, mute, duck
    }

    static let currentVersion = 1
    var version: Int = currentVersion
    var mode: Mode
    var retainedPercent: Double = 20
    /// Nil is the legacy single-percentage format and remains valid on import.
    var retainedPercentByDevice: [String: Double]? = nil
    var fadeDownSeconds: Double = 1.5
    var fadeUpSeconds: Double = 1.5
    var restoreDelaySeconds: Double = 0

    var isValid: Bool {
        version == Self.currentVersion && (0...100).contains(retainedPercent)
            && [fadeDownSeconds, fadeUpSeconds, restoreDelaySeconds].allSatisfy {
                $0.isFinite && (0...10).contains($0)
            }
            && (retainedPercentByDevice?.count ?? 0) <= 64
            && (retainedPercentByDevice ?? [:]).allSatisfy { uid, value in
                !uid.isEmpty && uid.utf8.count <= 1024 && value.isFinite && (0...100).contains(value)
            }
    }

    func retainedPercent(for deviceUID: String?) -> Double {
        guard let deviceUID, let value = retainedPercentByDevice?[deviceUID] else { return retainedPercent }
        return value
    }

    mutating func setRetainedPercent(_ value: Double, for deviceUID: String?) {
        guard let deviceUID, !deviceUID.isEmpty else { retainedPercent = value; return }
        var values = retainedPercentByDevice ?? [:]
        values[deviceUID] = value
        retainedPercentByDevice = values
    }

    static func migrated(legacyMute: Bool) -> Self {
        Self(mode: legacyMute ? .mute : .unchanged)
    }
}

/// Transition calculations operate on a monotonic time supplied by the caller.
struct AudioDuckingTransition {
    let start: [Float]
    let end: [Float]
    let startTime: TimeInterval
    let duration: TimeInterval

    init?(start: [Float], end: [Float], startTime: TimeInterval, duration: TimeInterval) {
        guard !start.isEmpty, start.count == end.count, startTime.isFinite,
              duration.isFinite, duration >= 0,
              (start + end).allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { return nil }
        self.start = start
        self.end = end
        self.startTime = startTime
        self.duration = duration
    }

    func values(at time: TimeInterval) -> [Float] {
        let fraction: Float
        if duration == 0 {
            fraction = 1
        } else if !time.isFinite {
            fraction = 0
        } else {
            fraction = Float(max(0, min(1, (time - startTime) / duration)))
        }
        if fraction == 0 { return start }
        if fraction == 1 { return end }
        return zip(start, end).map { $0 + ($1 - $0) * fraction }
    }

    func isComplete(at time: TimeInterval) -> Bool {
        time.isFinite && (duration == 0 || time >= startTime + duration)
    }
}
