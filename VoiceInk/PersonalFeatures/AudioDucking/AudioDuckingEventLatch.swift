import Foundation

/// The latch is advanced on the event callback itself, before queueing cleanup.
/// Events not yet delivered by macOS and a HAL write already in flight remain
/// outside this ordering guarantee.
final class AudioDuckingEventLatch {
    private let lock = NSLock()
    private var epoch: UInt64 = 0
    private var token: AudioDuckingLease.Token?
    private var admittedEpoch: UInt64?
    private var mutePauseEpoch: UInt64?

    /// The caller holds its own serialized runtime queue. Events cannot advance
    /// the latch between the epoch check and the durable journal transition.
    func performIfCurrent<T>(_ expected: UInt64, _ operation: () throws -> T) rethrows -> T? {
        lock.lock(); defer { lock.unlock() }
        guard epoch == expected else { return nil }
        return try operation()
    }

    /// The final admission and the synchronous HAL call share the event lock.
    /// Journal I/O happens before admission. CoreAudio listeners use our explicit
    /// dispatch queue (never NULL); these non-I/O-context notifications are async.
    /// A hardware effect after the setter returns still requires confirmation.
    func performWrite(ifCurrent expected: AudioDuckingLease.Token,
                      _ operation: () -> AudioDuckingWriteResult) -> AudioDuckingWriteResult {
        lock.lock(); defer { lock.unlock() }
        guard token == expected, admittedEpoch == epoch else { return .notAttempted }
        return operation()
    }

    func currentEpoch() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        return epoch
    }

    func admit(_ token: AudioDuckingLease.Token, observedEpoch: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard epoch == observedEpoch else { return false }
        self.token = token
        mutePauseEpoch = nil
        admittedEpoch = observedEpoch
        return true
    }

    /// A healthy pending write may finish for an older recording. Transfer its
    /// event lease without advancing or recapturing the epoch. Invalidation and
    /// a temporary mute pause both deny the transfer until safely reconciled.
    func handoff(from previous: AudioDuckingLease.Token, to next: AudioDuckingLease.Token) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard token == previous, admittedEpoch == epoch else { return false }
        token = next
        return true
    }

    func permits(_ token: AudioDuckingLease.Token) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return self.token == token && admittedEpoch == epoch
    }

    /// A temporary mute observation cannot reopen a previously invalidated
    /// lease. Later route/sleep events invalidate this exact resume proof.
    func pause(ifCurrent expected: AudioDuckingLease.Token) -> UInt64? {
        lock.lock(); defer { lock.unlock() }
        guard token == expected, admittedEpoch == epoch || mutePauseEpoch == epoch else { return nil }
        epoch &+= 1
        mutePauseEpoch = epoch
        return epoch
    }

    func resume(_ expected: AudioDuckingLease.Token, after observedEpoch: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard token == expected, epoch == observedEpoch, mutePauseEpoch == observedEpoch else { return false }
        mutePauseEpoch = nil
        admittedEpoch = observedEpoch
        return true
    }

    func isMutePaused(_ expected: AudioDuckingLease.Token) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return token == expected && mutePauseEpoch == epoch
    }

    func pendingInvalidation() -> AudioDuckingLease.Token? {
        lock.lock(); defer { lock.unlock() }
        guard admittedEpoch != nil, admittedEpoch != epoch else { return nil }
        return token
    }

    func invalidate() -> AudioDuckingLease.Token? {
        lock.lock(); defer { lock.unlock() }
        epoch &+= 1
        mutePauseEpoch = nil
        return token
    }

    func invalidate(ifCurrent expected: AudioDuckingLease.Token) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard token == expected else { return false }
        epoch &+= 1
        mutePauseEpoch = nil
        return true
    }

    /// An idle failed-cycle reset retires its event lease atomically. A route
    /// or sleep event observed during archival vetoes this exact reset attempt.
    func retireIfCurrent(_ expectedEpoch: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard epoch == expectedEpoch else { return false }
        epoch &+= 1
        token = nil
        admittedEpoch = nil
        mutePauseEpoch = nil
        return true
    }

    func clear(_ token: AudioDuckingLease.Token) {
        lock.lock(); defer { lock.unlock() }
        guard self.token == token else { return }
        self.token = nil
        mutePauseEpoch = nil
        admittedEpoch = nil
    }
}

/// Final admission for the delayed legacy mute path. The service serializes
/// journal and unsettled-write access; the event latch fences the actual setter.
/// An already-owned unmute uses its separate restoration obligation.
enum RecordingMuteAdmission {
    static func perform(deviceID: UInt32, journal: AudioDuckingRecoveryJournal?,
                        unsettled: AudioDuckingUnsettledWrites, latch: AudioDuckingEventLatch,
                        readIdentity: () -> (deviceID: UInt32, uid: String)?,
                        operation: () -> Bool) -> Bool {
        let epoch = latch.currentEpoch()
        guard let journal, let selected = readIdentity(), selected.deviceID == deviceID,
              !selected.uid.isEmpty, unsettled.allows(selected.uid),
              (try? journal.admitsNewAudioEffect(forUID: selected.uid)) == true else { return false }
        return latch.performIfCurrent(epoch) {
            guard let current = readIdentity(), current.deviceID == deviceID,
                  current.uid == selected.uid else { return false }
            return operation()
        } ?? false
    }
}
