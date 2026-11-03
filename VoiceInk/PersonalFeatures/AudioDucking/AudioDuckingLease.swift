import Foundation

/// Pure ownership state. The caller serializes access and verifies the device and
/// current control values before applying every proposed write.
struct AudioDuckingLease {
    struct Token: Equatable {
        let sessionID: UUID
        let generation: UInt64
        let cycleID: UUID
    }

    private(set) var sessionID: UUID?
    private(set) var generation: UInt64 = 0
    private var cycleID = UUID()
    var token: Token? {
        sessionID.map { Token(sessionID: $0, generation: generation, cycleID: cycleID) }
    }
    private(set) var baseline: [Float]?
    private(set) var lastConfirmed: [Float]?
    private(set) var restoreDeadline: TimeInterval?
    private(set) var transition: AudioDuckingTransition?
    private(set) var suppressed = false
    private(set) var restoring = false
    private(set) var ended = false

    @discardableResult
    mutating func begin(_ id: UUID) -> Token {
        generation &+= 1
        if baseline == nil { cycleID = UUID() }
        sessionID = id
        suppressed = false
        restoring = false
        ended = false
        restoreDeadline = nil
        transition = nil
        return token!
    }

    /// Call only after the first device snapshot has been validated. An inherited
    /// lease keeps its original baseline rather than recording a reduced level.
    mutating func activate(_ token: Token, values: [Float], config: AudioDuckingConfiguration, now: TimeInterval) -> Bool {
        guard token == self.token, !suppressed, !ended, !restoring, config.isValid,
              config.mode == .duck, now.isFinite, !values.isEmpty,
              values.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { return false }
        if baseline == nil {
            baseline = values
            lastConfirmed = values
        }
        guard let original = baseline, let confirmed = lastConfirmed,
              original.count == values.count, confirmed.count == values.count else { return false }
        let target = original.map { $0 * Float(config.retainedPercent / 100) }
        transition = AudioDuckingTransition(start: values, end: target, startTime: now, duration: config.fadeDownSeconds)
        return transition != nil
    }

    /// Duplicate stops do not reset the original deadline or cancel the lease.
    mutating func end(_ token: Token, config: AudioDuckingConfiguration, now: TimeInterval) {
        guard token == self.token, !suppressed else { return }
        ended = true
        guard !restoring, baseline != nil, now.isFinite, config.isValid else { return }
        restoring = true
        restoreDeadline = now + config.restoreDelaySeconds
        transition = nil
    }

    mutating func prepareRestore(_ token: Token, current: [Float], config: AudioDuckingConfiguration, now: TimeInterval) -> Bool {
        guard token == self.token, !suppressed, restoring, let deadline = restoreDeadline,
              config.isValid, now.isFinite, now >= deadline, let original = baseline,
              current.count == original.count else { return false }
        if transition == nil {
            transition = AudioDuckingTransition(start: current, end: original, startTime: now, duration: config.fadeUpSeconds)
        }
        return transition != nil
    }

    mutating func confirm(_ values: [Float], token: Token) {
        guard self.token == token, !suppressed, baseline?.count == values.count,
              values.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { return }
        lastConfirmed = values
    }

    mutating func finishRestore(token: Token) {
        guard self.token == token, !suppressed, restoring else { return }
        baseline = nil
        lastConfirmed = nil
        restoreDeadline = nil
        transition = nil
        restoring = false
        generation &+= 1
    }

    /// A route change or sleep revokes the current session's future writes.
    mutating func invalidate(token: Token) {
        guard token == self.token else { return }
        generation &+= 1
        suppressed = true
        baseline = nil
        lastConfirmed = nil
        restoreDeadline = nil
        transition = nil
        restoring = false
    }
}
