import Foundation

/// Tracks ownership per hardware control, never from an unconfirmed write.
struct AudioDuckingControlOwnership {
    enum State: Equatable {
        case untouched
        case owned(lastConfirmed: Float)
        case uncertain
        case relinquished
    }

    let baseline: [Float]
    private(set) var states: [State]

    init?(baseline: [Float]) {
        guard !baseline.isEmpty, baseline.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { return nil }
        self.baseline = baseline
        states = Array(repeating: .untouched, count: baseline.count)
    }

    /// The owner requests restoration to the original baseline after a manual
    /// recording-level adjustment. This is not attributed to an app setter.
    mutating func adoptUserLevel(_ values: [Float]) -> Bool {
        guard values.count == baseline.count, values.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { return false }
        states = zip(values, baseline).map { value, original in
            value == original ? .untouched : .owned(lastConfirmed: value)
        }
        return true
    }

    /// A failed setter or absent readback is ambiguous even when the setter
    /// reported an error: the hardware may already have applied the change.
    mutating func recordWrite(index: Int, before: Float, reportedSuccess: Bool, readback: Float?) {
        guard states.indices.contains(index), before.isFinite, (0...1).contains(before) else { return }
        switch states[index] {
        case .uncertain, .relinquished:
            return
        case .untouched:
            guard before == baseline[index] else { states[index] = .relinquished; return }
        case .owned(let lastConfirmed):
            guard before == lastConfirmed else { states[index] = .relinquished; return }
        }
        guard reportedSuccess, let value = readback, value.isFinite, (0...1).contains(value) else {
            states[index] = .uncertain
            return
        }
        if value == baseline[index] {
            states[index] = .untouched
        } else {
            states[index] = .owned(lastConfirmed: value)
        }
    }

    /// Returns a baseline only when the current readback still matches a value
    /// confirmed after our write. Callers must independently verify identity,
    /// topology and the applicable normal-write or named-cleanup authorization.
    mutating func ownedRestoreTarget(index: Int, current: Float) -> Float? {
        guard states.indices.contains(index), case .owned(let confirmed) = states[index] else { return nil }
        guard current.isFinite, current == confirmed else {
            states[index] = .relinquished
            return nil
        }
        return baseline[index]
    }

    mutating func relinquish(index: Int) {
        guard states.indices.contains(index) else { return }
        states[index] = .relinquished
    }

    mutating func markUncertain(index: Int) {
        guard states.indices.contains(index) else { return }
        states[index] = .uncertain
    }
}
