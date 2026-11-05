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

    static func scalarMatches(_ lhs: Float, _ rhs: Float) -> Bool {
        lhs.isFinite && rhs.isFinite && (lhs == rhs || abs(lhs - rhs) <= max(0.000001, max(lhs.ulp, rhs.ulp) * 4))
    }

    static func levelsMatch(_ lhs: [Float], _ rhs: [Float]) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { scalarMatches($0.0, $0.1) }
    }

    /// HAL may emit duplicate mute/topology notifications while volume changes.
    /// Only observed control or mute changes invalidate the session.
    func requiresInvalidation(comparedWith other: Self) -> Bool {
        !hasSameControls(as: other) || muted == nil || muted != other.muted
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
        AudioDuckingOutputSnapshot.scalarMatches(lhs, rhs)
    }
    enum Status: Equatable { case idle, active, restoring, unavailable, incomplete }
    private let output: AudioDuckingOutput
    private let journal: AudioDuckingRecoveryJournal?
    private let normalWriteAllowed: (AudioDuckingLease.Token) -> Bool
    private let writeAdmission: (AudioDuckingLease.Token, () -> AudioDuckingWriteResult) -> AudioDuckingWriteResult
    private var cycleDeviceUID: String?
    var quarantinedDeviceUID: String? { unresolvedWrite ? cycleDeviceUID : nil }
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
    private struct DeferredBegin {
        let token: AudioDuckingLease.Token
        let desired: AudioDuckingConfiguration
        var activationRequested = false
        var endedAt: TimeInterval?
    }
    private var deferredBegin: DeferredBegin?
    var deferredBeginToken: AudioDuckingLease.Token? { deferredBegin?.token }
    var deferredBeginReady: Bool {
        deferredBegin != nil && pendingWrite == nil && !unresolvedWrite && !hasUnfinishedAsyncFrame
    }
    private struct AsyncFrame {
        let token: AudioDuckingLease.Token
        let transition: AudioDuckingTransition
        let values: [Float]
    }
    private var asyncFrame: AsyncFrame?
    private var hasUnfinishedAsyncFrame: Bool {
        guard let frame = asyncFrame, let confirmed = lease.lastConfirmed else { return false }
        return !AudioDuckingOutputSnapshot.levelsMatch(confirmed, frame.values)
    }
    private(set) var transitionSettled = false
    private struct RetainedLevelIntent {
        let percent: Double
        var pending: Bool
    }
    // The selected value belongs to the ownership cycle, not to a Stop waiter
    // or service pause buffer. Stop cancels its effect, never the selection.
    private var retainedLevelIntent: RetainedLevelIntent?
    private(set) var manualAdjustment: (id: UUID, uid: String, percent: Double)?

    private func adoptUserLevel(_ current: AudioDuckingOutputSnapshot, token: AudioDuckingLease.Token) -> Bool {
        guard pendingWrite == nil, !unresolvedWrite, !lease.ended, !lease.restoring,
              let baseline = lease.baseline, let peak = baseline.max(), peak > 0,
              let level = current.values.max(), var config = effectiveConfiguration,
              var ledger = AudioDuckingControlOwnership(baseline: baseline) else { return false }
        let percent = min(100, max(0, Double(level / peak) * 100)).rounded()
        do { try persist(.confirmed, snapshot: current, baseline: baseline) }
        catch { failureReason = "journal_confirm_failed"; unresolvedWrite = true; cleanupUnsafe = true; relinquish(token: token, incomplete: true); return true }
        guard lease.adoptUserLevel(current.values, token: token) else { return false }
        asyncFrame = nil
        transitionSettled = true
        // The owner explicitly defines manual volume changes during recording
        // as a retained-level adjustment; the original baseline is preserved.
        guard ledger.adoptUserLevel(current.values) else { return false }
        ownership = ledger
        config.retainedPercent = percent
        effectiveConfiguration = config
        retainedLevelIntent = RetainedLevelIntent(percent: percent, pending: false)
        manualAdjustment = (UUID(), current.uid, percent)
        return true
    }

    var hasPendingWrite: Bool { pendingWrite != nil }
    var needsRecordingHandoff: Bool { pendingWrite != nil || deferredBegin != nil || hasUnfinishedAsyncFrame }
    var hasOwnershipCycle: Bool {
        lease.baseline != nil || deferredBegin != nil || unresolvedWrite || pendingWrite != nil || (ownership?.states.contains { state in
            switch state { case .owned, .uncertain: return true; case .untouched, .relinquished: return false }
        } ?? false)
    }

    init(output: AudioDuckingOutput, journal: AudioDuckingRecoveryJournal? = nil,
         normalWriteAllowed: @escaping (AudioDuckingLease.Token) -> Bool = { _ in true },
         writeAdmission: ((AudioDuckingLease.Token, () -> AudioDuckingWriteResult) -> AudioDuckingWriteResult)? = nil) {
        self.output = output
        self.journal = journal
        self.normalWriteAllowed = normalWriteAllowed
        self.writeAdmission = writeAdmission ?? { token, operation in
            normalWriteAllowed(token) ? operation() : .notAttempted
        }
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
        try journal.writeOwned(record)
    }

    @discardableResult
    func begin(sessionID: UUID, desired: AudioDuckingConfiguration, deferUntilAdmitted: Bool = false) -> AudioDuckingLease.Token? {
        guard !unresolvedWrite else { status = .incomplete; return nil }
        if deferUntilAdmitted || needsRecordingHandoff {
            // Keep the issued setter's token, listener and deadline alive. The
            // newest recording waits for its confirmation, never for the fade.
            guard desired.isValid, let previous = lease.token, lease.baseline != nil,
                  let initial = beginSnapshot, let current = output.readDefault(),
                  !current.requiresInvalidation(comparedWith: initial) else { return nil }
            let next = AudioDuckingLease.Token(sessionID: sessionID,
                generation: previous.generation &+ 1, cycleID: previous.cycleID)
            deferredBegin = DeferredBegin(token: next, desired: desired)
            return next
        }
        return beginImmediately(sessionID: sessionID, desired: desired)
    }

    private func beginImmediately(sessionID: UUID, desired: AudioDuckingConfiguration,
                                  inheriting: Bool = false) -> AudioDuckingLease.Token? {
        failureReason = "none"
        failureLevels = nil
        asyncFrame = nil
        transitionSettled = false
        guard desired.isValid else { status = .unavailable; return nil }
        let inherited = inheriting || hasOwnershipCycle
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
                  snapshot.muted == old.muted, lease.lastConfirmed.map({ AudioDuckingOutputSnapshot.levelsMatch(snapshot.values, $0) }) == true else {
                relinquish(token: token, incomplete: true)
                return nil
            }
            if let intent = retainedLevelIntent {
                effectiveConfiguration?.retainedPercent = intent.percent
                retainedLevelIntent?.pending = false
            }
        } else {
            retainedLevelIntent = nil
            var effective = desired
            effective.retainedPercent = desired.retainedPercent(for: snapshot.uid)
            effectiveConfiguration = effective
            beginSnapshot = snapshot
            cycleDeviceUID = snapshot.uid
        }
        status = .active
        return token
    }

    /// Transfer only after the original notification path has confirmed the
    /// issued write. Admission atomically checks the old event lease before the
    /// new token may write; a route/sleep invalidation cannot be reopened here.
    @discardableResult
    func completeDeferredBegin(now: TimeInterval,
        admit: (AudioDuckingLease.Token, AudioDuckingLease.Token, AudioDuckingOutputSnapshot) -> Bool
    ) -> AudioDuckingLease.Token? {
        guard deferredBeginReady, let request = deferredBegin,
              let previous = lease.token, normalWriteAllowed(previous) else { return nil }
        guard let snapshot = beginSnapshot, let current = output.readDefault(),
              !current.requiresInvalidation(comparedWith: snapshot),
              lease.lastConfirmed.map({ AudioDuckingOutputSnapshot.levelsMatch(current.values, $0) }) == true else {
            failureReason = "handoff_snapshot_changed"
            relinquish(token: previous, incomplete: true)
            return nil
        }
        // Admission can race a mute pause on the notification queue. Keep the
        // original lease and request intact until the event latch transfers;
        // failed admission may be a temporary pause, not lost ownership.
        guard admit(previous, request.token, snapshot) else { return nil }
        deferredBegin = nil
        guard let next = beginImmediately(sessionID: request.token.sessionID,
                                          desired: request.desired, inheriting: true) else { return nil }
        guard next == request.token else {
            invalidate(token: next)
            return nil
        }
        if let stoppedAt = request.endedAt {
            end(token: next, now: stoppedAt)
        } else {
            if request.activationRequested { activate(token: next, now: now) }
        }
        return next
    }

    /// The caller invokes this only after the existing chime-protection delay.
    func activate(token: AudioDuckingLease.Token, now: TimeInterval) {
        if deferredBegin?.token == token {
            if deferredBegin?.endedAt == nil { deferredBegin?.activationRequested = true }
            return
        }
        guard deferredBegin == nil, token == lease.token, !lease.suppressed, !lease.ended,
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
        guard AudioDuckingOutputSnapshot.levelsMatch(current.values, expected) else { relinquish(token: token, incomplete: ownership != nil); return }
        guard lease.activate(token, values: current.values, config: config, now: now) else { return }
        asyncFrame = nil
        transitionSettled = false
        if ownership == nil { ownership = AudioDuckingControlOwnership(baseline: initial.values) }
        tick(token: token, now: now)
    }

    func end(token: AudioDuckingLease.Token, now: TimeInterval) {
        if deferredBegin?.token == token {
            if now.isFinite, deferredBegin?.endedAt == nil { deferredBegin?.endedAt = now }
            return
        }
        guard deferredBegin == nil, token == lease.token, let config = effectiveConfiguration else { return }
        retainedLevelIntent?.pending = false
        // A system-volume/mute callback may still be queued when Stop arrives.
        // Reconcile its observed metadata before entering restoration state.
        if pendingWrite == nil { _ = observeMuteChange(token: token) }
        // Read the owner's last level before changing to restoration state.
        if pendingWrite == nil, let initial = beginSnapshot,
           let current = output.readDefault(), !current.requiresInvalidation(comparedWith: initial),
           let confirmed = lease.lastConfirmed,
           !AudioDuckingOutputSnapshot.levelsMatch(current.values, confirmed) {
            _ = adoptUserLevel(current, token: token)
        }
        lease.end(token, config: config, now: now)
        transitionSettled = false
        if lease.restoring { status = .restoring }
        else if ownership == nil { clear(token: token) }
    }

    /// Only the retained percentage is live; the original baseline remains
    /// owned until restoration and timing remains fixed for this cycle.
    func updateRetainedPercent(_ percent: Double, token: AudioDuckingLease.Token, now: TimeInterval,
                               deferEffects: Bool = false) {
        guard now.isFinite, percent.isFinite, (0...100).contains(percent) else { return }
        if deferredBegin?.token == token {
            retainedLevelIntent = RetainedLevelIntent(percent: percent, pending: deferredBegin?.endedAt == nil)
            return
        }
        guard deferredBegin == nil, token == lease.token, !lease.suppressed,
              var config = effectiveConfiguration, config.mode == .duck else { return }
        retainedLevelIntent = RetainedLevelIntent(percent: percent, pending: !lease.ended && !lease.restoring)
        // A settings change after Stop is remembered for an inherited recording,
        // but must never retarget the old restoration.
        guard !lease.ended, !lease.restoring else { return }
        if deferEffects || pendingWrite != nil || hasUnfinishedAsyncFrame { return }
        retainedLevelIntent?.pending = false
        asyncFrame = nil
        config.retainedPercent = percent
        effectiveConfiguration = config
        guard lease.baseline != nil, let initial = beginSnapshot,
              let current = output.readDefault(), current.hasSameControls(as: initial),
              current.muted == initial.muted, lease.lastConfirmed.map({ AudioDuckingOutputSnapshot.levelsMatch(current.values, $0) }) == true else { return }
        if lease.activate(token, values: current.values, config: config, now: now) {
            transitionSettled = false
            tick(token: token, now: now)
        }
    }

    /// The service resumes only after the exact mute observation is reconciled.
    /// A pending write/frame consumes this same intent through volumeChanged.
    @discardableResult
    func resumeRetainedPercent(token: AudioDuckingLease.Token, now: TimeInterval) -> Bool {
        guard deferredBegin == nil, token == lease.token, !lease.ended, !lease.restoring,
              !lease.suppressed, normalWriteAllowed(token), pendingWrite == nil,
              !hasUnfinishedAsyncFrame, let intent = retainedLevelIntent, intent.pending else { return false }
        updateRetainedPercent(intent.percent, token: token, now: now)
        return true
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
        // Drain only the already sampled stereo pair, preserving balance.
        // Never sample another old-session frame while a recording waits.
        guard deferredBegin == nil || hasUnfinishedAsyncFrame else { return }
        guard let current = output.readDefault(), current.hasSameControls(as: initial),
              current.muted == initial.muted else {
            failureReason = "snapshot_changed"
            relinquish(token: token, incomplete: true); return
        }
        guard lease.lastConfirmed.map({ AudioDuckingOutputSnapshot.levelsMatch(current.values, $0) }) == true else {
            if adoptUserLevel(current, token: token) { return }
            // No setter is pending here. A different current value belongs to
            // the user, so relinquish and remove the old recovery obligation.
            failureReason = "user_volume_changed"
            do { try journal?.clear() }
            catch { unresolvedWrite = true; cleanupUnsafe = true }
            relinquish(token: token, incomplete: true)
            return
        }
        let transition: AudioDuckingTransition
        let targets: [Float]
        if output.requiresWriteNotification, let frame = asyncFrame, frame.token == token,
           !AudioDuckingOutputSnapshot.levelsMatch(current.values, frame.values) {
            // Complete the sampled pair before advancing time, retargeting, or
            // preparing restoration from a partially changed stereo level.
            transition = frame.transition
            targets = frame.values
        } else {
            asyncFrame = nil
            if lease.restoring, lease.transition == nil {
                guard lease.prepareRestore(token, current: current.values, config: config, now: now) else { return }
            }
            guard let active = lease.transition else { return }
            transition = active
            let sampled = active.values(at: now)
            if output.requiresWriteNotification {
                let converted = sampled.indices.compactMap { index in
                    output.canonicalTarget(deviceID: initial.deviceID, element: initial.elements[index], value: sampled[index])
                }
                guard converted.count == sampled.count, converted.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
                    failureReason = "target_conversion_failed"
                    relinquish(token: token, incomplete: hasOwnershipCycle); return
                }
                targets = converted
                asyncFrame = AsyncFrame(token: token, transition: active, values: converted)
            } else { targets = sampled }
        }
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
                switch writeAdmission(token, {
                    output.writeDefault(deviceID: initial.deviceID, element: initial.elements[index], value: target, expected: observed)
                }) {
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
            let result = writeAdmission(token) {
                output.writeDefault(deviceID: initial.deviceID, element: initial.elements[index], value: target, expected: observed)
            }
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
        asyncFrame = nil
        transitionSettled = transition.isComplete(at: now)
        guard deferredBegin == nil else { return }
        if lease.restoring && transitionSettled {
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
                retainedLevelIntent = nil
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
            guard !AudioDuckingOutputSnapshot.levelsMatch(current.values, confirmed) else { return }
            guard let latest = output.readDefault(), latest == current else { return }
            if adoptUserLevel(current, token: token) { return }
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
            if AudioDuckingOutputSnapshot.levelsMatch(observed.values, pending.before.values) { return }
            guard AudioDuckingOutputSnapshot.levelsMatch(observed.values, current.values) else {
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
        if AudioDuckingOutputSnapshot.levelsMatch(current.values, pending.before.values) { return }
        guard sameScalar(current.values[pending.index], pending.target),
              current.values.indices.allSatisfy({ $0 == pending.index || sameScalar(current.values[$0], pending.before.values[$0]) }) else {
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
        // Finish only this sampled channel pair before handoff. Its targets
        // were fixed before the new recording; do not resample or finalize the
        // old restore, even when its final frame reached the baseline.
        if deferredBegin != nil {
            if hasUnfinishedAsyncFrame { tick(token: token, now: now) }
            return
        }
        if let intent = retainedLevelIntent, intent.pending,
           asyncFrame.map({ AudioDuckingOutputSnapshot.levelsMatch(current.values, $0.values) }) ?? true {
            retainedLevelIntent?.pending = false
            asyncFrame = nil
            updateRetainedPercent(intent.percent, token: token, now: now)
            return
        }
        tick(token: token, now: now)
    }

    /// Called with the event latch paused. A user mute change with no pending
    /// setter may update metadata, but never the pre-recording volume or mute
    /// hardware. An in-flight setter still makes a real mute change uncertain.
    func observeMuteChange(token: AudioDuckingLease.Token) -> Bool {
        guard token == lease.token, !lease.suppressed, !unresolvedWrite,
              let initial = beginSnapshot, let current = output.readDefault(),
              current.hasSameControls(as: initial), current.muted != nil else { return false }
        if current.muted == initial.muted { return true }
        guard pendingWrite == nil, !lease.ended, !lease.restoring, lease.baseline != nil else { return false }
        beginSnapshot = AudioDuckingOutputSnapshot(deviceID: initial.deviceID, uid: initial.uid,
            elements: initial.elements, values: initial.values, muted: current.muted, control: initial.control,
            stereoChannels: initial.stereoChannels, balance: initial.balance, channelLayout: initial.channelLayout)
        // A mute-only change is not a new volume choice. Preserve an explicit
        // queued percentage and any sampled fade instead of publishing an old
        // readback as a manual level adjustment.
        if lease.lastConfirmed.map({ AudioDuckingOutputSnapshot.levelsMatch(current.values, $0) }) == true,
           let baseline = lease.baseline {
            // A crash must retain the newly observed mute metadata alongside
            // the original volume obligation, without adopting a new level.
            do { try persist(.confirmed, snapshot: current, baseline: baseline) }
            catch {
                failureReason = "journal_confirm_failed"
                unresolvedWrite = true
                cleanupUnsafe = true
                relinquish(token: token, incomplete: true)
                return false
            }
            return true
        }
        return adoptUserLevel(current, token: token) && !unresolvedWrite
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
        deferredBegin = nil
        asyncFrame = nil
        retainedLevelIntent = nil
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
        retainedLevelIntent = nil
        cleanupUnsafe = false
        beginSnapshot = nil
        effectiveConfiguration = nil
        status = .idle
    }
}

/// Presentation evidence captured once per recording, independent of runtime
/// cleanup. Retain it after Stop so the original level remains inspectable.
struct AudioDuckingRecordingVolume {
    private(set) var uid: String?
    private(set) var values: [Float]?

    mutating func capture(_ snapshot: AudioDuckingOutputSnapshot, inherited: [Float]? = nil) {
        let original = inherited ?? snapshot.values
        guard original.count == snapshot.elements.count, !original.isEmpty,
              original.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { return }
        uid = snapshot.uid
        values = original
    }

    func percent(forUID uid: String) -> Double? {
        guard self.uid == uid, let peak = values?.max() else { return nil }
        return Double(peak) * 100
    }
}
