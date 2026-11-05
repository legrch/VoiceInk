import Foundation

/// A named-device recovery is separate from the recording lease. The owner
/// must install the named-device listener before calling `issue`.
final class AudioDuckingRecoveryCoordinator {
    struct Plan {
        let record: AudioDuckingRecoveryRecord
        let snapshot: AudioDuckingOutputSnapshot
    }
    enum State { case idle, needsListener(Plan), waiting(Plan, deadline: TimeInterval), deferredMissing(deadline: TimeInterval), incomplete }
    private static let missingDeviceTTL: TimeInterval = 30
    private let journal: AudioDuckingRecoveryJournal
    private let output: AudioDuckingOutput
    private let resolve: (String) -> UInt32?
    private(set) var state: State = .idle
    private(set) var unsettledDeviceUID: String?

    init(journal: AudioDuckingRecoveryJournal, output: AudioDuckingOutput, resolve: @escaping (String) -> UInt32?) {
        self.journal = journal
        self.output = output
        self.resolve = resolve
    }

    /// Inventory is read-only with respect to audio hardware.
    func prepare(continuousOwnership: Bool = false, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard unsettledDeviceUID == nil else { state = .incomplete; return }
        do {
            switch try journal.read() {
            case .absent: state = .idle
            case .invalid: state = .incomplete
            case .record(let record):
                if record.phase == .restored { try journal.clear(); state = .idle; return }
                guard now.isFinite else { state = .incomplete; return }
                guard let device = resolve(record.deviceUID) else {
                    state = .deferredMissing(deadline: now + Self.missingDeviceTTL)
                    return
                }
                guard record.phase == .confirmed else { state = .incomplete; return }
                let current = output.readNamed(deviceID: device)
                switch record.decision(for: current, continuousOwnership: continuousOwnership) {
                case .restore:
                    guard let current else { state = .incomplete; return }
                    state = .needsListener(Plan(record: record, snapshot: current))
                case .finished, .relinquish:
                    try journal.clear()
                    state = .idle
                case .invalid, .ambiguous, .unavailable: state = .incomplete
                }
            }
        } catch { state = .incomplete }
    }

    func issue(now: TimeInterval, allowed: () -> Bool = { true },
               writeAdmission: (() -> AudioDuckingWriteResult) -> AudioDuckingWriteResult = { $0() }) {
        guard case .needsListener(let plan) = state, now.isFinite,
              plan.snapshot.elements.count == 1,
              let current = output.readNamed(deviceID: plan.snapshot.deviceID),
              current == plan.snapshot else { state = .incomplete; return }
        do {
            try journal.writeOwned(plan.record.replacing(phase: .writeIntent, intended: plan.record.baseline))
            guard allowed() else {
                try journal.writeOwned(plan.record)
                state = .incomplete
                return
            }
            switch writeAdmission({
                output.writeOwnedDevice(deviceID: current.deviceID, element: current.elements[0],
                                        value: plan.record.baseline[0], expected: current)
            }) {
            case .notAttempted:
                try journal.writeOwned(plan.record)
                state = .incomplete
            case .attempted(false):
                unsettledDeviceUID = plan.record.deviceUID
                state = .incomplete
            case .attempted(true):
                unsettledDeviceUID = plan.record.deviceUID
                state = .waiting(plan, deadline: now + 2)
            }
        } catch { state = .incomplete }
    }

    func notified(now: TimeInterval) {
        guard case .waiting(let plan, _) = state,
              let current = output.readNamed(deviceID: plan.snapshot.deviceID),
              current.hasSameControls(as: plan.snapshot), current.muted == plan.snapshot.muted else { return }
        if current.values == plan.snapshot.values { return }
        guard current.values.count == plan.record.baseline.count,
              zip(current.values, plan.record.baseline).allSatisfy({ abs($0.0 - $0.1) <= 0.000001 }) else {
            state = .incomplete
            return
        }
        do {
            try journal.writeOwned(plan.record.replacing(phase: .restored, confirmed: current.values))
            try journal.clear()
            unsettledDeviceUID = nil
            state = .idle
        } catch { state = .incomplete }
    }

    func tick(now: TimeInterval) {
        switch state {
        case .waiting(_, let deadline), .deferredMissing(let deadline):
            if now >= deadline { state = .incomplete }
        default: break
        }
    }

    /// An in-flight setter cannot be cancelled; keep its durable intent.
    func invalidate() {
        switch state { case .idle: break; default: state = .incomplete }
    }
}
