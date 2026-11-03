import Foundation

/// Hardware snapshots identify the exact device and ordered output controls.
struct AudioDuckingOutputSnapshot: Equatable {
    enum Control: String, Codable { case physicalMain, virtualMain, physicalChannels }
    let deviceID: UInt32
    let uid: String
    let elements: [UInt32]
    let values: [Float]
    let muted: Bool?
    let control: Control
    let stereoChannels: [UInt32]
    let balance: Float?
    let channelLayout: Data

    init(deviceID: UInt32, uid: String, elements: [UInt32], values: [Float], muted: Bool?, control: Control = .physicalMain, stereoChannels: [UInt32] = [], balance: Float? = nil, channelLayout: Data = Data()) {
        self.deviceID = deviceID
        self.uid = uid
        self.elements = elements
        self.values = values
        self.muted = muted
        self.control = control
        self.stereoChannels = stereoChannels
        self.balance = balance
        self.channelLayout = channelLayout
    }

    func hasSameControls(as other: Self) -> Bool {
        let sameBalance: Bool
        switch (balance, other.balance) {
        case (nil, nil): sameBalance = true
        case let (left?, right?): sameBalance = abs(left - right) <= 0.000001
        default: sameBalance = false
        }
        return deviceID == other.deviceID && uid == other.uid && control == other.control && elements == other.elements
            && stereoChannels == other.stereoChannels && channelLayout == other.channelLayout && sameBalance
            && values.count == elements.count && other.values.count == other.elements.count
    }
}

/// A serialized owner supplies the real device or a deterministic test double.
/// Named writes are exclusively for relinquishing a previously owned device.
enum AudioDuckingWriteResult { case notAttempted, attempted(Bool) }
protocol AudioDuckingOutput {
    var requiresWriteNotification: Bool { get }
    func readDefault() -> AudioDuckingOutputSnapshot?
    func readNamed(deviceID: UInt32) -> AudioDuckingOutputSnapshot?
    func writeDefault(deviceID: UInt32, element: UInt32, value: Float, expected: AudioDuckingOutputSnapshot) -> AudioDuckingWriteResult
    func writeOwnedDevice(deviceID: UInt32, element: UInt32, value: Float, expected: AudioDuckingOutputSnapshot) -> AudioDuckingWriteResult
    func canonicalTarget(deviceID: UInt32, element: UInt32, value: Float) -> Float?
}

extension AudioDuckingOutput {
    var requiresWriteNotification: Bool { false }
    func canonicalTarget(deviceID: UInt32, element: UInt32, value: Float) -> Float? { value }
}

/// All calls, including hardware invalidation, must be serialized by the owner.
/// Time is supplied by a monotonic clock; this object does not create tasks.
final class AudioDuckingRuntime {
    private func sameScalar(_ lhs: Float, _ rhs: Float) -> Bool {
        lhs == rhs || abs(lhs - rhs) <= max(0.000001, max(lhs.ulp, rhs.ulp) * 4)
    }
    enum Status: Equatable { case idle, active, restoring, unavailable, incomplete }
    private let output: AudioDuckingOutput
    private let journal: AudioDuckingRecoveryJournal?
    private let normalWriteAllowed: (AudioDuckingLease.Token) -> Bool
    private(set) var lease = AudioDuckingLease()
    private(set) var status: Status = .idle
    private(set) var failureReason = "none"
    private(set) var failureLevels: (before: Float, target: Float, observed: Float)?
    private(set) var effectiveConfiguration: AudioDuckingConfiguration?
    private var beginSnapshot: AudioDuckingOutputSnapshot?
    var capturedOutput: AudioDuckingOutputSnapshot? { beginSnapshot }
    private var ownership: AudioDuckingControlOwnership?
    private var cleanupUnsafe = false
    private var unresolvedWrite = false
    var isQuarantined: Bool { unresolvedWrite }
    private struct PendingWrite {
        let token: AudioDuckingLease.Token
        let index: Int
        let before: AudioDuckingOutputSnapshot
        let target: Float
        let deadline: TimeInterval
    }
    private var pendingWrite: PendingWrite?
    private var pendingRetainedPercent: Double?
    var hasPendingWrite: Bool { pendingWrite != nil }
    var hasOwnershipCycle: Bool {
        unresolvedWrite || pendingWrite != nil || (ownership?.states.contains { state in
            switch state { case .owned, .uncertain: return true; case .untouched, .relinquished: return false }
        } ?? false)
    }

    init(output: AudioDuckingOutput, journal: AudioDuckingRecoveryJournal? = nil, normalWriteAllowed: @escaping (AudioDuckingLease.Token) -> Bool = { _ in true }) {
        self.output = output
        self.journal = journal
        self.normalWriteAllowed = normalWriteAllowed
    }

    private func persist(_ phase: AudioDuckingRecoveryRecord.Phase, snapshot: AudioDuckingOutputSnapshot,
                         baseline: [Float], intended: [Float]? = nil) throws {
        guard let journal else { return }
        guard let token = lease.token else { throw AudioDuckingRecoveryJournal.JournalError.invalidRecord }
        let record = AudioDuckingRecoveryRecord(version: AudioDuckingRecoveryRecord.currentVersion,
            cycleID: token.cycleID, deviceUID: snapshot.uid, control: snapshot.control,
            elements: snapshot.elements, stereoChannels: snapshot.stereoChannels, channelLayout: snapshot.channelLayout,
            balance: snapshot.balance, muted: snapshot.muted, baseline: baseline, confirmed: snapshot.values,
            phase: phase, intended: intended)
        try journal.write(record)
    }

    @discardableResult
    func begin(sessionID: UUID, desired: AudioDuckingConfiguration) -> AudioDuckingLease.Token? {
        // A later HAL completion can still change the device after a stop.
        // Never recapture that uncertain output as the next session's baseline.
        guard !unresolvedWrite, pendingWrite == nil else { status = .incomplete; return nil }
        failureReason = "none"
        failureLevels = nil
        guard desired.isValid else { status = .unavailable; return nil }
        let inherited = hasOwnershipCycle
        if !inherited, ownership != nil, let old = lease.token { clear(token: old) }
        let token = lease.begin(sessionID)
        guard let snapshot = output.readDefault(), snapshot.values.count == snapshot.elements.count,
              !snapshot.values.isEmpty, snapshot.values.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
            relinquish(token: token, incomplete: inherited)
            if !inherited { status = .unavailable }
            return nil
        }
        if inherited {
            guard let old = beginSnapshot, snapshot.hasSameControls(as: old),
                  snapshot.muted == old.muted, snapshot.values == lease.lastConfirmed else {
                relinquish(token: token, incomplete: true)
                return nil
            }
        } else {
            var effective = desired
            effective.retainedPercent = desired.retainedPercent(for: snapshot.uid)
            effectiveConfiguration = effective
            beginSnapshot = snapshot
        }
        status = .active
        return token
    }

    /// The caller invokes this only after the existing chime-protection delay.
    func activate(token: AudioDuckingLease.Token, now: TimeInterval) {
        guard token == lease.token, !lease.suppressed, !lease.ended,
              let config = effectiveConfiguration, config.mode == .duck,
              let initial = beginSnapshot else { return }
        guard let current = output.readDefault(), current.hasSameControls(as: initial),
              current.muted == initial.muted, current.muted != true else {
            let inherited = hasOwnershipCycle
            relinquish(token: token, incomplete: inherited)
            if !inherited { status = .unavailable }
            return
        }
        let expected = lease.lastConfirmed ?? initial.values
        guard current.values == expected else { relinquish(token: token, incomplete: ownership != nil); return }
        guard lease.activate(token, values: current.values, config: config, now: now) else { return }
        if ownership == nil { ownership = AudioDuckingControlOwnership(baseline: initial.values) }
        tick(token: token, now: now)
    }

    func end(token: AudioDuckingLease.Token, now: TimeInterval) {
        guard token == lease.token, let config = effectiveConfiguration else { return }
        pendingRetainedPercent = nil
        lease.end(token, config: config, now: now)
        if lease.restoring { status = .restoring }
        else if ownership == nil { clear(token: token) }
    }

    /// Only the retained percentage is live; the original baseline remains
    /// owned until restoration and timing remains fixed for this cycle.
    func updateRetainedPercent(_ percent: Double, token: AudioDuckingLease.Token, now: TimeInterval) {
        guard token == lease.token, !lease.suppressed, !lease.ended, !lease.restoring,
              now.isFinite, percent.isFinite, (0...100).contains(percent),
              var config = effectiveConfiguration, config.mode == .duck else { return }
        if pendingWrite != nil { pendingRetainedPercent = percent; return }
        config.retainedPercent = percent
        effectiveConfiguration = config
        guard lease.transition != nil, let initial = beginSnapshot,
              let current = output.readDefault(), current.hasSameControls(as: initial),
              current.muted == initial.muted, current.values == lease.lastConfirmed else { return }
        if lease.activate(token, values: current.values, config: config, now: now) {
            tick(token: token, now: now)
        }
    }

    func tick(token: AudioDuckingLease.Token, now: TimeInterval) {
        guard token == lease.token, !lease.suppressed, let config = effectiveConfiguration,
              let initial = beginSnapshot, var ledger = ownership else { return }
        if let pending = pendingWrite {
            if now >= pending.deadline {
                failureReason = "notification_timeout"
                if let current = output.readDefault(), current.hasSameControls(as: pending.before),
                   current.values.indices.contains(pending.index) {
                    failureLevels = (pending.before.values[pending.index], pending.target, current.values[pending.index])
                }
                pendingWrite = nil
                unresolvedWrite = true
                cleanupUnsafe = true
                relinquish(token: token, incomplete: true)
            }
            return
        }
        guard let current = output.readDefault(), current.hasSameControls(as: initial),
              current.muted == initial.muted else {
            failureReason = "snapshot_changed"
            relinquish(token: token, incomplete: true); return
        }
        guard current.values == lease.lastConfirmed else {
            // No setter is pending here. A different current value belongs to
            // the user, so relinquish and remove the old recovery obligation.
            failureReason = "user_volume_changed"
            do { try journal?.clear() }
            catch { unresolvedWrite = true; cleanupUnsafe = true }
            relinquish(token: token, incomplete: true)
            return
        }
        if lease.restoring, lease.transition == nil {
            guard lease.prepareRestore(token, current: current.values, config: config, now: now) else { return }
        }
        guard let transition = lease.transition else { return }
        let targets = transition.values(at: now)
        var observed = current
        for index in targets.indices {
            guard token == lease.token, !lease.suppressed, normalWriteAllowed(token) else { return }
            let before = observed.values[index]
            guard let target = output.canonicalTarget(deviceID: initial.deviceID,
                                                      element: initial.elements[index], value: targets[index]),
                  target.isFinite, (0...1).contains(target) else {
                failureReason = "target_conversion_failed"
                relinquish(token: token, incomplete: hasOwnershipCycle); return
            }
            if sameScalar(target, before) { continue }
            if output.requiresWriteNotification {
                var intended = observed.values
                intended[index] = target
                do { try persist(.writeIntent, snapshot: observed, baseline: ledger.baseline, intended: intended) }
                catch {
                    failureReason = "journal_write_failed"
                    cleanupUnsafe = true
                    relinquish(token: token, incomplete: true)
                    return
                }
                pendingWrite = PendingWrite(token: token, index: index, before: observed, target: target, deadline: now + 2)
                switch output.writeDefault(deviceID: initial.deviceID, element: initial.elements[index], value: target, expected: observed) {
                case .notAttempted:
                    pendingWrite = nil
                    failureReason = "preflight_changed"
                    do { try persist(.confirmed, snapshot: observed, baseline: ledger.baseline) }
                    catch { unresolvedWrite = true }
                    relinquish(token: token, incomplete: hasOwnershipCycle)
                case .attempted(false):
                    failureReason = "setter_failed"
                    pendingWrite = nil
                    unresolvedWrite = true
                    cleanupUnsafe = true
                    relinquish(token: token, incomplete: true)
                case .attempted(true): break
                }
                return
            }
            let result = output.writeDefault(deviceID: initial.deviceID, element: initial.elements[index], value: target, expected: observed)
            let success: Bool
            switch result {
            case .notAttempted:
                relinquish(token: token, incomplete: hasOwnershipCycle); return
            case .attempted(let wrote): success = wrote
            }
            let after = output.readDefault()
            let valid = after.map { $0.hasSameControls(as: initial) && $0.muted == initial.muted } ?? false
            let readback = valid ? after?.values[index] : nil
            if !success { unresolvedWrite = true }
            if success, valid, readback != target {
                // An unchanged or different readback may be a pending HAL write
                // or a user adjustment. Neither grants restoration ownership.
                ledger.markUncertain(index: index)
                ownership = ledger
                unresolvedWrite = true
                cleanupUnsafe = true
                relinquish(token: token, incomplete: true)
                return
            }
            ledger.recordWrite(index: index, before: before, reportedSuccess: success, readback: readback)
            if valid, let after {
                for other in after.values.indices where other != index && after.values[other] != observed.values[other] {
                    cleanupUnsafe = true
                    unresolvedWrite = true
                    ledger.markUncertain(index: other)
                }
            } else {
                // An unreadable result cannot rule out coupled control effects.
                unresolvedWrite = true
                for other in ledger.states.indices where other != index { ledger.markUncertain(index: other) }
            }
            ownership = ledger
            guard success, valid, let next = after,
                  next.values.indices.allSatisfy({ $0 == index || next.values[$0] == observed.values[$0] }) else {
                relinquish(token: token, incomplete: true); return
            }
            observed = next
            lease.confirm(observed.values, token: token)
        }
        if lease.restoring && transition.isComplete(at: now) {
            // A quantized control is complete only if readback reached baseline;
            // otherwise leave the remaining obligation visible, never invent it.
            if zip(observed.values, ledger.baseline).allSatisfy({ pair in sameScalar(pair.0, pair.1) }) {
                do {
                    try persist(.restored, snapshot: observed, baseline: ledger.baseline)
                    try journal?.clear()
                } catch {
                    failureReason = "journal_clear_failed"
                    unresolvedWrite = true
                    cleanupUnsafe = true
                    relinquish(token: token, incomplete: true)
                    return
                }
                lease.finishRestore(token: token)
                ownership = nil
                beginSnapshot = nil
                effectiveConfiguration = nil
                status = .idle
            } else {
                failureReason = "baseline_not_reached"
                relinquish(token: token, incomplete: true)
            }
        }
    }

    /// HAL notifications acknowledge a change, but do not identify the writer.
    /// Only an exact readback of the pending target permits further writes.
    func volumeChanged(token: AudioDuckingLease.Token, now: TimeInterval,
                       observed: AudioDuckingOutputSnapshot? = nil) {
        guard token == lease.token, !lease.suppressed, normalWriteAllowed(token) else { return }
        if pendingWrite == nil {
            // A finished fade has no timer. Still observe user changes so a
            // later stop or route event cannot restore over the new volume.
            guard let initial = beginSnapshot, let confirmed = lease.lastConfirmed,
                  let current = observed ?? output.readDefault() else { return }
            guard current.hasSameControls(as: initial), current.muted == initial.muted else {
                failureReason = "snapshot_changed"
                relinquish(token: token, incomplete: true)
                return
            }
            guard current.values != confirmed else { return }
            failureReason = "user_volume_changed"
            do { try journal?.clear() }
            catch { unresolvedWrite = true; cleanupUnsafe = true }
            relinquish(token: token, incomplete: ownership != nil)
            return
        }
        guard let pending = pendingWrite, pending.token == token, var ledger = ownership,
              let current = output.readDefault(), current.hasSameControls(as: pending.before),
              current.muted == pending.before.muted else { return }
        if let observed {
            guard observed.hasSameControls(as: pending.before), observed.muted == pending.before.muted else {
                failureReason = "notification_device_changed"
                pendingWrite = nil
                unresolvedWrite = true
                cleanupUnsafe = true
                relinquish(token: token, incomplete: true)
                return
            }
            // A queued notification must not be attributed a newer readback.
            if observed.values == pending.before.values { return }
            guard observed.values == current.values else {
                failureReason = "notification_readback_changed"
                pendingWrite = nil
                unresolvedWrite = true
                cleanupUnsafe = true
                relinquish(token: token, incomplete: true)
                return
            }
        }
        // A duplicate notification from a previous write can arrive before this
        // setter takes effect. Keep waiting; the timeout preserves quarantine.
        if current.values == pending.before.values { return }
        guard sameScalar(current.values[pending.index], pending.target),
              current.values.indices.allSatisfy({ $0 == pending.index || current.values[$0] == pending.before.values[$0] }) else {
            failureReason = "notification_unexpected_value"
            failureLevels = (pending.before.values[pending.index], pending.target, current.values[pending.index])
            pendingWrite = nil
            unresolvedWrite = true
            cleanupUnsafe = true
            relinquish(token: token, incomplete: true)
            return
        }
        pendingWrite = nil
        do { try persist(.confirmed, snapshot: current, baseline: ledger.baseline) }
        catch {
            failureReason = "journal_confirm_failed"
            unresolvedWrite = true
            cleanupUnsafe = true
            relinquish(token: token, incomplete: true)
            return
        }
        ledger.recordWrite(index: pending.index, before: pending.before.values[pending.index], reportedSuccess: true, readback: current.values[pending.index])
        ownership = ledger
        lease.confirm(current.values, token: token)
        if let percent = pendingRetainedPercent {
            pendingRetainedPercent = nil
            updateRetainedPercent(percent, token: token, now: now)
            return
        }
        tick(token: token, now: now)
    }

    /// The caller first latches normal writes at the observed route/sleep boundary.
    /// Named cleanup is bounded and never scheduled for reconnect or wake.
    func invalidate(token: AudioDuckingLease.Token) {
        guard token == lease.token else { return }
        failureReason = "device_or_sleep_invalidated"
        relinquish(token: token, incomplete: ownership != nil)
    }

    private func relinquish(token: AudioDuckingLease.Token, incomplete: Bool) {
        guard token == lease.token else { return }
        pendingRetainedPercent = nil
        if pendingWrite != nil {
            pendingWrite = nil
            unresolvedWrite = true
            cleanupUnsafe = true
        }
        // Retire every normal event before attempting bounded named cleanup.
        let initial = beginSnapshot
        var ledger = ownership
        lease.invalidate(token: token)
        if cleanupUnsafe {
            // A coupled effect or pending asynchronous write makes every further
            // setter unsafe, including a seemingly owned-channel restore.
            ownership = nil
            beginSnapshot = nil
            effectiveConfiguration = nil
            cleanupUnsafe = false
            status = .incomplete
            return
        }
        if output.requiresWriteNotification, ledger != nil {
            // A route/sleep invalidation has retired the normal listener lease.
            // An unacknowledged named-device setter would create a second
            // asynchronous effect that we cannot safely follow after invalidation.
            let hadOwnership = hasOwnershipCycle
            ownership = nil
            beginSnapshot = nil
            effectiveConfiguration = nil
            status = hadOwnership ? .incomplete : (incomplete ? .unavailable : .idle)
            return
        }
        var failed = false
        if let initial, var owned = ledger {
            cleanup: for index in initial.elements.indices {
                guard let current = output.readNamed(deviceID: initial.deviceID),
                      current.hasSameControls(as: initial), current.muted == initial.muted else { failed = true; break }
                guard let target = owned.ownedRestoreTarget(index: index, current: current.values[index]) else { continue }
                let result = output.writeOwnedDevice(deviceID: initial.deviceID, element: initial.elements[index], value: target, expected: current)
                let wrote: Bool
                switch result {
                case .notAttempted:
                    failed = true
                    break cleanup
                case .attempted(let success):
                    wrote = success
                }
                let readback = output.readNamed(deviceID: initial.deviceID)
                guard wrote, let next = readback, next.hasSameControls(as: initial),
                      next.muted == initial.muted, next.values[index] == target,
                      next.values.indices.allSatisfy({ $0 == index || next.values[$0] == current.values[$0] }) else {
                    unresolvedWrite = true
                    failed = true; break
                }
                owned.recordWrite(index: index, before: current.values[index], reportedSuccess: true, readback: next.values[index])
            }
            ledger = owned
            if owned.states.contains(where: { state in
                switch state { case .owned, .uncertain, .relinquished: return true; case .untouched: return false }
            }) { failed = true }
        }
        ownership = nil
        cleanupUnsafe = false
        beginSnapshot = nil
        effectiveConfiguration = nil
        status = failed ? .incomplete : (incomplete ? .unavailable : .idle)
    }

    private func clear(token: AudioDuckingLease.Token) {
        guard token == lease.token else { return }
        lease.invalidate(token: token)
        ownership = nil
        pendingRetainedPercent = nil
        cleanupUnsafe = false
        beginSnapshot = nil
        effectiveConfiguration = nil
        status = .idle
    }
}
