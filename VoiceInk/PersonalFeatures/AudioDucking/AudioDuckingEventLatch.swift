import Foundation

/// The latch is advanced on the event callback itself, before queueing cleanup.
/// Events not yet delivered by macOS and a HAL write already in flight remain
/// outside this ordering guarantee.
final class AudioDuckingEventLatch {
    private let lock = NSLock()
    private var epoch: UInt64 = 0
    private var token: AudioDuckingLease.Token?
    private var admittedEpoch: UInt64?

    /// The caller holds its own serialized runtime queue. Events cannot advance
    /// the latch between the epoch check and the durable journal transition.
    func performIfCurrent<T>(_ expected: UInt64, _ operation: () throws -> T) rethrows -> T? {
        lock.lock(); defer { lock.unlock() }
        guard epoch == expected else { return nil }
        return try operation()
    }

    func currentEpoch() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        return epoch
    }

    func admit(_ token: AudioDuckingLease.Token, observedEpoch: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard epoch == observedEpoch else { return false }
        self.token = token
        admittedEpoch = observedEpoch
        return true
    }

    func permits(_ token: AudioDuckingLease.Token) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return self.token == token && admittedEpoch == epoch
    }

    func pendingInvalidation() -> AudioDuckingLease.Token? {
        lock.lock(); defer { lock.unlock() }
        guard admittedEpoch != nil, admittedEpoch != epoch else { return nil }
        return token
    }

    func invalidate() -> AudioDuckingLease.Token? {
        lock.lock(); defer { lock.unlock() }
        epoch &+= 1
        return token
    }

    func invalidate(ifCurrent expected: AudioDuckingLease.Token) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard token == expected else { return false }
        epoch &+= 1
        return true
    }

    func clear(_ token: AudioDuckingLease.Token) {
        lock.lock(); defer { lock.unlock() }
        guard self.token == token else { return }
        self.token = nil
        admittedEpoch = nil
    }
}
