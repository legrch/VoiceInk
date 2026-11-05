import Foundation

enum AudioDelay {
    static func nanoseconds(_ seconds: Double) -> UInt64? {
        guard seconds.isFinite, seconds >= 0 else { return nil }
        let value = seconds * 1_000_000_000
        guard value.isFinite, value < Double(UInt64.max) else { return nil }
        return UInt64(value)
    }

    /// Older backups could persist invalid values. Do not abandon an owned
    /// restoration because a previously stored delay cannot be scheduled.
    static func restorationNanoseconds(_ seconds: Double) -> UInt64 {
        nanoseconds(seconds) ?? 0
    }
}
