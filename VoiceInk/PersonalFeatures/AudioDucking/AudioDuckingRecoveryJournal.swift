import Foundation
import Darwin

/// Process-lifetime evidence of unsettled setters survives runtime replacement.
/// User acknowledgment, elapsed time and matching readback cannot clear it.
struct AudioDuckingUnsettledWrites {
    private var deviceUIDs: Set<String> = []
    mutating func retain(_ uid: String?) {
        if let uid { deviceUIDs.insert(uid) }
    }
    func allows(_ uid: String) -> Bool { !deviceUIDs.contains(uid) }
}

/// Persisted device identity never relies on an AudioDeviceID surviving restart.
struct AudioDuckingRecoveryRecord: Codable, Equatable {
    static let currentVersion = 1
    enum Phase: String, Codable { case confirmed, writeIntent, restored }
    let version: Int
    let cycleID: UUID
    let deviceUID: String
    let control: AudioDuckingOutputSnapshot.Control
    let elements: [UInt32]
    let stereoChannels: [UInt32]
    let channelLayout: Data
    let balance: Float?
    let muted: Bool?
    let baseline: [Float]
    let confirmed: [Float]
    let phase: Phase
    let intended: [Float]?

    var isValid: Bool {
        version == Self.currentVersion && !deviceUID.isEmpty && deviceUID.utf8.count <= 1024 &&
        !elements.isEmpty && elements.count <= 2 && Set(elements).count == elements.count &&
        baseline.count == elements.count && confirmed.count == elements.count &&
        (baseline + confirmed).allSatisfy { $0.isFinite && (0...1).contains($0) } &&
        (balance == nil || (balance!.isFinite && (0...1).contains(balance!))) &&
        channelLayout.count <= 4096 &&
        (control != .virtualMain || (elements == [0] && stereoChannels.count == 2 &&
            stereoChannels[0] != 0 && stereoChannels[1] != 0 && stereoChannels[0] != stereoChannels[1] &&
            balance != nil && !channelLayout.isEmpty)) &&
        (control != .physicalChannels || (elements.count == 2 && elements == stereoChannels &&
            !elements.contains(0) && balance == nil && !channelLayout.isEmpty)) &&
        (phase == .writeIntent ? intended?.count == elements.count : intended == nil) &&
        (intended ?? []).allSatisfy { $0.isFinite && (0...1).contains($0) }
    }

    /// An observation describes the current values; it does not establish who
    /// changed them or whether a previous asynchronous setter is still pending.
    enum Observation: String, Equatable {
        case invalid, unavailable, metadataChanged, baseline, confirmed, target, externallyChanged
    }

    func observe(_ current: AudioDuckingOutputSnapshot?) -> Observation {
        guard isValid else { return .invalid }
        guard let current else { return .unavailable }
        let sameBalance: Bool
        switch (current.balance, balance) {
        case (nil, nil): sameBalance = true
        case let (left?, right?): sameBalance = abs(left - right) <= 0.000001
        default: sameBalance = false
        }
        guard current.uid == deviceUID, current.control == control, current.elements == elements,
              current.stereoChannels == stereoChannels, current.channelLayout == channelLayout,
              sameBalance, current.muted == muted else { return .metadataChanged }
        if current.values == baseline { return .baseline }
        if current.values == confirmed { return .confirmed }
        if let intended, current.values == intended { return .target }
        return .externallyChanged
    }

    /// A persisted value match is never proof of ownership. Continuous in-memory
    /// ownership must be independently established before issuing a restore.
    func decision(for current: AudioDuckingOutputSnapshot?, continuousOwnership: Bool = false) -> Decision {
        guard isValid else { return .invalid }
        if phase == .restored { return .finished }
        if phase == .writeIntent {
            // A different or matching readback cannot cancel an in-flight write.
            switch observe(current) {
            case .invalid: return .invalid
            case .unavailable: return .unavailable
            default: return .ambiguous
            }
        }
        switch observe(current) {
        case .invalid: return .invalid
        case .unavailable: return .unavailable
        case .metadataChanged, .externallyChanged: return .relinquish
        case .baseline:
            // A pending write may still complete after this observation.
            return phase == .writeIntent ? .ambiguous : .finished
        case .target: return .ambiguous
        case .confirmed:
            guard phase == .confirmed, continuousOwnership else { return .ambiguous }
            return .restore
        }
    }

    enum Decision: Equatable { case restore, finished, relinquish, unavailable, ambiguous, invalid }

    func replacing(phase: Phase, confirmed: [Float]? = nil, intended: [Float]? = nil) -> Self {
        Self(version: version, cycleID: cycleID, deviceUID: deviceUID, control: control,
             elements: elements, stereoChannels: stereoChannels, channelLayout: channelLayout,
             balance: balance, muted: muted, baseline: baseline, confirmed: confirmed ?? self.confirmed,
             phase: phase, intended: intended)
    }
}

/// A held advisory lock prevents two local app instances from writing the same
/// recovery record. Failure is reported to the caller; it never grants a write.
final class AudioDuckingRecoveryJournal {
    enum ReadResult { case absent, record(AudioDuckingRecoveryRecord), invalid }
    enum JournalError: Error { case unavailable, locked, invalidRecord, io }
    private let directory: URL
    private let recordURL: URL
    private let lockFD: Int32

    init(directory: URL) throws {
        self.directory = directory
        self.recordURL = directory.appendingPathComponent("recovery-v1.json")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch { throw JournalError.unavailable }
        let descriptor = open(directory.appendingPathComponent("recovery.lock").path,
                              O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else { throw JournalError.unavailable }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw JournalError.locked
        }
        lockFD = descriptor
    }

    deinit {
        flock(lockFD, LOCK_UN)
        close(lockFD)
    }

    func read() throws -> ReadResult {
        guard FileManager.default.fileExists(atPath: recordURL.path) else { return .absent }
        let attributes: [FileAttributeKey: Any]
        do { attributes = try FileManager.default.attributesOfItem(atPath: recordURL.path) }
        catch { throw JournalError.io }
        guard let size = attributes[.size] as? NSNumber, size.intValue > 0, size.intValue <= 65_536 else { return .invalid }
        let data: Data
        do { data = try Data(contentsOf: recordURL) } catch { throw JournalError.io }
        guard let record = try? JSONDecoder().decode(AudioDuckingRecoveryRecord.self, from: data), record.isValid else { return .invalid }
        return .record(record)
    }

    /// Re-evaluate after lifecycle invalidation, before a replacement cycle is
    /// admitted. A different output may proceed only after durable preservation.
    func prepareRecordingCycle(inheriting cycleID: UUID?, selectedUID: String) throws -> Bool {
        switch try read() {
        case .absent: return true
        case .invalid: throw JournalError.invalidRecord
        case .record(let record):
            if record.phase == .restored { try clear(); return true }
            if record.cycleID == cycleID { return true }
            guard record.deviceUID != selectedUID else { return false }
            try holdMissingDevice(record)
            return true
        }
    }

    /// The journal has a process-lifetime exclusive lock. Serialized writers
    /// must never replace a different cycle's unresolved active evidence.
    func writeOwned(_ record: AudioDuckingRecoveryRecord) throws {
        switch try read() {
        case .absent: break
        case .invalid: throw JournalError.invalidRecord
        case .record(let current):
            guard current.cycleID == record.cycleID else { throw JournalError.invalidRecord }
        }
        try write(record)
    }

    func write(_ record: AudioDuckingRecoveryRecord) throws {
        guard record.isValid, let data = try? JSONEncoder().encode(record), data.count <= 65_536 else { throw JournalError.invalidRecord }
        let temp = directory.appendingPathComponent(".recovery-\(UUID().uuidString).tmp")
        let fd = open(temp.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, mode_t(0o600))
        guard fd >= 0 else { throw JournalError.io }
        var succeeded = false
        defer {
            close(fd)
            if !succeeded { unlink(temp.path) }
        }
        let written = data.withUnsafeBytes { buffer -> Bool in
            guard let base = buffer.baseAddress else { return false }
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(fd, base.advanced(by: offset), buffer.count - offset)
                if count <= 0 { return false }
                offset += count
            }
            return true
        }
        guard written, fsync(fd) == 0, rename(temp.path, recordURL.path) == 0 else { throw JournalError.io }
        succeeded = true
        try syncDirectory()
    }

    private func archivedRecords(prefix: String) throws -> [(URL, AudioDuckingRecoveryRecord)] {
        let entries = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
        var records: [(URL, AudioDuckingRecoveryRecord)] = []
        for entry in entries where entry.lastPathComponent.hasPrefix(prefix) && entry.pathExtension == "json" {
            let attrs = try FileManager.default.attributesOfItem(atPath: entry.path)
            guard let size = attrs[.size] as? NSNumber, size.intValue > 0, size.intValue <= 65_536,
                  let data = try? Data(contentsOf: entry),
                  let record = try? JSONDecoder().decode(AudioDuckingRecoveryRecord.self, from: data), record.isValid else {
                throw JournalError.invalidRecord
            }
            records.append((entry, record))
        }
        return records.sorted { $0.0.lastPathComponent < $1.0.lastPathComponent }
    }

    private func preserve(_ record: AudioDuckingRecoveryRecord, prefix: String) throws {
        let archive = directory.appendingPathComponent("\(prefix)\(record.cycleID.uuidString).json")
        let bytes = try JSONEncoder().encode(record)
        let fd = open(archive.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, mode_t(0o600))
        if fd < 0 {
            guard errno == EEXIST,
                  let existing = try? Data(contentsOf: archive),
                  let decoded = try? JSONDecoder().decode(AudioDuckingRecoveryRecord.self, from: existing),
                  decoded == record else { throw JournalError.io }
        } else {
            var success = false
            defer { close(fd); if !success { unlink(archive.path) } }
            let wrote = bytes.withUnsafeBytes { buffer -> Bool in
                guard let base = buffer.baseAddress else { return false }
                var offset = 0
                while offset < buffer.count {
                    let count = Darwin.write(fd, base.advanced(by: offset), buffer.count - offset)
                    if count <= 0 { return false }
                    offset += count
                }
                return true
            }
            guard wrote, fsync(fd) == 0 else { throw JournalError.io }
            success = true
        }
        // A pre-existing archive may have been created before a crash, so its
        // directory entry must be made durable before clearing the active slot.
        try syncDirectory()
    }

    /// Preserve an absent device without declaring it acknowledged. Its UID
    /// remains blocked, while other devices can use the active journal slot.
    func holdMissingDevice(_ record: AudioDuckingRecoveryRecord) throws {
        guard case .record(let current) = try read(), current == record, record.phase != .restored else {
            throw JournalError.invalidRecord
        }
        try preserve(record, prefix: "held-")
        try clear()
    }

    var hasHeldEvidence: Bool { (try? !archivedRecords(prefix: "held-").isEmpty) == true }

    struct Acknowledgment: Codable, Equatable {
        let record: AudioDuckingRecoveryRecord
        let reason: String
        let acknowledgedAt: Date
        let observedUID: String
        let observedValues: [Float]
        let observedMute: Bool?
    }

    enum AcknowledgmentReason: String {
        case userSetVolume = "user_set_volume"
        case userReenabledDucking = "user_reenabled_ducking"
    }

    /// An unresolved record for the selected UID can be explicitly acknowledged.
    /// The original phase is retained; acknowledgment is not write confirmation.
    /// The archive is durable before the blocking record is removed.
    func pendingRecovery(for uid: String) throws -> (URL, AudioDuckingRecoveryRecord)? {
        switch try read() {
        case .invalid: throw JournalError.invalidRecord
        case .record(let record):
            if record.deviceUID == uid && record.phase != .restored { return (recordURL, record) }
        case .absent: break
        }
        for prefix in ["held-", "acknowledged-"] {
            if let entry = try archivedRecords(prefix: prefix).first(where: { $0.1.deviceUID == uid && $0.1.phase != .restored }) {
                return entry
            }
        }
        return nil
    }

    func acknowledge(uid: String, observed: AudioDuckingOutputSnapshot, now: Date,
                     reason: AcknowledgmentReason = .userSetVolume,
                     commit: (() throws -> Void) throws -> Bool) throws -> Bool {
        guard uid == observed.uid, observed.muted != nil, now.timeIntervalSince1970.isFinite,
              !observed.values.isEmpty, observed.values.count == observed.elements.count,
              observed.values.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
              let (source, record) = try pendingRecovery(for: uid),
              record.deviceUID == uid, record.phase != .restored else { return false }
        let receiptURL = directory.appendingPathComponent("accepted-\(record.cycleID.uuidString).json")
        let receipt = Acknowledgment(record: record, reason: reason.rawValue, acknowledgedAt: now,
            observedUID: observed.uid, observedValues: observed.values, observedMute: observed.muted)
        if FileManager.default.fileExists(atPath: receiptURL.path) {
            guard let bytes = try? Data(contentsOf: receiptURL), bytes.count <= 65_536,
                  let existing = try? JSONDecoder().decode(Acknowledgment.self, from: bytes),
                  existing.record == record, existing.observedUID == uid else { throw JournalError.invalidRecord }
        }
        do {
            let bytes = try JSONEncoder().encode(receipt)
            guard bytes.count <= 65_536 else { throw JournalError.invalidRecord }
            let temp = directory.appendingPathComponent(".ack-\(UUID().uuidString).tmp")
            let fd = open(temp.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, mode_t(0o600))
            guard fd >= 0 else { throw JournalError.io }
            var installed = false
            defer { close(fd); if !installed { unlink(temp.path) } }
            let wrote = bytes.withUnsafeBytes { buffer -> Bool in
                guard let base = buffer.baseAddress else { return false }
                var offset = 0
                while offset < buffer.count {
                    let count = Darwin.write(fd, base.advanced(by: offset), buffer.count - offset)
                    if count <= 0 { return false }
                    offset += count
                }
                return true
            }
            guard wrote, fsync(fd) == 0, rename(temp.path, receiptURL.path) == 0 else { throw JournalError.io }
            installed = true
        }
        try syncDirectory()
        // A failed commit leaves the original blocking record intact.
        return try commit {
            guard unlink(source.path) == 0 else { throw JournalError.io }
            try syncDirectory()
        }
    }

    /// A fresh writer must honor both active and durable per-output evidence.
    /// This does not restrict restoration of a mute the caller already owns.
    func admitsNewAudioEffect(forUID uid: String) throws -> Bool {
        guard !uid.isEmpty else { throw JournalError.invalidRecord }
        switch try read() {
        case .invalid: throw JournalError.invalidRecord
        case .record(let record) where record.deviceUID == uid && record.phase != .restored:
            return false
        case .absent, .record: break
        }
        return try !isAcknowledgedDeviceBlocked(uid)
    }

    /// Invalid evidence fails closed, including for an unrelated device.
    func isAcknowledgedDeviceBlocked(_ uid: String) throws -> Bool {
        guard !uid.isEmpty else { throw JournalError.invalidRecord }
        let records = try archivedRecords(prefix: "held-") + archivedRecords(prefix: "acknowledged-")
        return records.contains { $0.1.deviceUID == uid }
    }

    func clear() throws {
        if unlink(recordURL.path) != 0 && errno != ENOENT { throw JournalError.io }
        try syncDirectory()
    }

    private func syncDirectory() throws {
        let fd = open(directory.path, O_RDONLY)
        guard fd >= 0 else { throw JournalError.io }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw JournalError.io }
    }
}
