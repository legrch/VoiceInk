import Foundation

func check(_ value: @autoclosure () -> Bool, _ message: String) {
    guard value() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
}

func record(phase: AudioDuckingRecoveryRecord.Phase, intended: [Float]? = nil) -> AudioDuckingRecoveryRecord {
    AudioDuckingRecoveryRecord(version: 1, cycleID: UUID(), deviceUID: "device-uid", control: .virtualMain,
                               elements: [0], stereoChannels: [1, 2], channelLayout: Data([1, 2]),
                               balance: 0.5, muted: false, baseline: [0.6], confirmed: [0.12],
                               phase: phase, intended: intended)
}
func snapshot(uid: String = "device-uid", value: Float = 0.12, balance: Float = 0.5) -> AudioDuckingOutputSnapshot {
    AudioDuckingOutputSnapshot(deviceID: 42, uid: uid, elements: [0], values: [value], muted: false,
                               control: .virtualMain, stereoChannels: [1, 2], balance: balance, channelLayout: Data([1, 2]))
}

let confirmed = record(phase: .confirmed)
check(confirmed.observe(snapshot()) == .confirmed, "confirmed value is observed")
check(confirmed.decision(for: snapshot()) == .ambiguous, "a match after restart does not prove ownership")
check(confirmed.decision(for: snapshot(), continuousOwnership: true) == .restore, "continuous ownership permits bounded recovery")
check(confirmed.observe(snapshot(value: 0.6)) == .baseline, "baseline is distinguishable")
check(confirmed.observe(snapshot(value: 0.2)) == .externallyChanged, "external value is distinguishable")
let intendedRecord = record(phase: .writeIntent, intended: [0.2])
check(intendedRecord.observe(snapshot(value: 0.2)) == .target, "pending target is distinguishable")
check(intendedRecord.decision(for: snapshot(value: 0.6)) == .ambiguous, "baseline does not cancel an outstanding write")
check(intendedRecord.decision(for: snapshot(value: 0.4)) == .ambiguous, "an external change does not cancel an outstanding write")
check(intendedRecord.decision(for: snapshot(uid: "different")) == .ambiguous, "changed metadata does not cancel an outstanding write")
check(confirmed.decision(for: snapshot(uid: "different")) == .relinquish, "device UID must match")
check(confirmed.decision(for: snapshot(value: 0.2)) == .relinquish, "changed user volume is never overwritten")
check(confirmed.decision(for: snapshot(balance: 0.7)) == .relinquish, "changed balance is never overwritten")
check(confirmed.decision(for: nil) == .unavailable, "missing device cannot be restored")
check(record(phase: .writeIntent, intended: [0.2]).decision(for: snapshot()) == .ambiguous,
      "an interrupted write is never automatically replayed")
check(record(phase: .restored).decision(for: nil) == .finished, "completed restoration needs no write")
let channelsRecord = AudioDuckingRecoveryRecord(version: 1, cycleID: UUID(), deviceUID: "channel-device", control: .physicalChannels,
    elements: [1, 2], stereoChannels: [1, 2], channelLayout: Data([1]), balance: nil, muted: false,
    baseline: [0.6, 0.3], confirmed: [0.12, 0.06], phase: .confirmed, intended: nil)
check(channelsRecord.isValid, "channel-only records preserve both baseline and confirmed controls")
let channelBytes = try JSONEncoder().encode(channelsRecord)
let decodedChannels = try JSONDecoder().decode(AudioDuckingRecoveryRecord.self, from: channelBytes)
check(decodedChannels == channelsRecord, "channel-only records survive relaunch")
let encoded = try JSONEncoder().encode(confirmed)
let decoded = try JSONDecoder().decode(AudioDuckingRecoveryRecord.self, from: encoded)
check(decoded == confirmed, "journal record round-trips")
let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("voiceink-journal-test-\(UUID().uuidString)")
defer { try? FileManager.default.removeItem(at: directory) }
let journal = try AudioDuckingRecoveryJournal(directory: directory)
if case .absent = try journal.read() {} else { check(false, "new journal is absent") }
try journal.write(confirmed)
if case .record(let loaded) = try journal.read() { check(loaded == confirmed, "stored record is intact") }
else { check(false, "stored record can be read") }
do {
    _ = try AudioDuckingRecoveryJournal(directory: directory)
    check(false, "second journal owner must not acquire the lock")
} catch AudioDuckingRecoveryJournal.JournalError.locked {}
try journal.clear()
if case .absent = try journal.read() {} else { check(false, "cleared journal is absent") }
try Data("not-json".utf8).write(to: directory.appendingPathComponent("recovery-v1.json"))
if case .invalid = try journal.read() {} else { check(false, "corrupt journal cannot authorize restoration") }
let ackDirectory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("voiceink-ack-test-\(UUID().uuidString)")
defer { try? FileManager.default.removeItem(at: ackDirectory) }
let ackJournal = try AudioDuckingRecoveryJournal(directory: ackDirectory)
let pending = record(phase: .writeIntent, intended: [0.2])
try ackJournal.write(pending)
try ackJournal.holdMissingDevice(pending)
check(ackJournal.hasHeldEvidence, "missing device is held without acknowledgment")
let heldOriginal = try ackJournal.isAcknowledgedDeviceBlocked("device-uid")
let heldOther = try ackJournal.isAcknowledgedDeviceBlocked("other-device")
check(heldOriginal && !heldOther, "held UID stays blocked without blocking another device")
let unknownMute = AudioDuckingOutputSnapshot(deviceID: 42, uid: "device-uid", elements: [0], values: [0.4], muted: nil,
    control: .virtualMain, stereoChannels: [1, 2], balance: 0.5, channelLayout: Data([1, 2]))
let noMuteAck = try ackJournal.acknowledge(uid: "device-uid", observed: unknownMute, now: Date(), commit: { operation in try operation(); return true })
check(!noMuteAck && ackJournal.hasHeldEvidence, "unreadable mute never releases the device")
let refused = try ackJournal.acknowledge(uid: "other-device", observed: snapshot(uid: "other-device"), now: Date(), commit: { operation in try operation(); return true })
check(!refused && ackJournal.hasHeldEvidence, "a different UID cannot acknowledge this intent")
let stopped = try ackJournal.acknowledge(uid: "device-uid", observed: snapshot(value: 0.4), now: Date(), commit: { _ in false })
check(!stopped && ackJournal.hasHeldEvidence, "a new pending write or changed device keeps quarantine")
let acknowledged = try ackJournal.acknowledge(uid: "device-uid", observed: snapshot(value: 0.4), now: Date(), commit: { operation in try operation(); return true })
check(acknowledged && !ackJournal.hasHeldEvidence, "explicit acknowledgment releases this pending UID")
if case .absent = try ackJournal.read() {} else { check(false, "active slot remains empty") }
let blockedOriginal = try ackJournal.isAcknowledgedDeviceBlocked("device-uid")
let blockedOther = try ackJournal.isAcknowledgedDeviceBlocked("other-device")
check(!blockedOriginal && !blockedOther, "accepted evidence does not quarantine either device")
let archives = try FileManager.default.contentsOfDirectory(at: ackDirectory, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("accepted-") }
check(archives.count == 1, "acknowledgment receipt is retained")
let archived = try JSONDecoder().decode(AudioDuckingRecoveryJournal.Acknowledgment.self, from: Data(contentsOf: archives[0]))
check(archived.record == pending && archived.record.phase == .writeIntent && archived.observedValues == [0.4] && archived.reason == "user_set_volume", "receipt preserves original evidence and manual level")
let forCorruption = try pendingForCorruption(ackJournal, pending)
try ackJournal.holdMissingDevice(forCorruption)
let heldFiles = try FileManager.default.contentsOfDirectory(at: ackDirectory, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("held-") }
try Data("corrupt".utf8).write(to: heldFiles[0])
do { _ = try ackJournal.isAcknowledgedDeviceBlocked("other-device"); check(false, "corrupt archive must fail closed") }
catch AudioDuckingRecoveryJournal.JournalError.invalidRecord {}
func pendingForCorruption(_ journal: AudioDuckingRecoveryJournal, _ item: AudioDuckingRecoveryRecord) throws -> AudioDuckingRecoveryRecord {
    try journal.write(item)
    return item
}
let activeDirectory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("voiceink-active-ack-\(UUID().uuidString)")
defer { try? FileManager.default.removeItem(at: activeDirectory) }
let activeJournal = try AudioDuckingRecoveryJournal(directory: activeDirectory)
try activeJournal.write(pending)
let activeAccepted = try activeJournal.acknowledge(uid: "device-uid", observed: snapshot(value: 0.2), now: Date(), commit: { operation in try operation(); return true })
check(activeAccepted, "the original active intent can be explicitly acknowledged")
if case .absent = try activeJournal.read() {} else { check(false, "only the accepted active intent is removed") }
let activeBlocked = try activeJournal.isAcknowledgedDeviceBlocked("device-uid")
check(!activeBlocked, "active UID can start a fresh cycle after acknowledgment")

let independentDirectory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("voiceink-independent-\(UUID().uuidString)")
defer { try? FileManager.default.removeItem(at: independentDirectory) }
let independentJournal = try AudioDuckingRecoveryJournal(directory: independentDirectory)
try independentJournal.write(pending)
try independentJournal.holdMissingDevice(pending)
let unrelated = AudioDuckingRecoveryRecord(version: 1, cycleID: UUID(), deviceUID: "other-device", control: .virtualMain,
    elements: [0], stereoChannels: [1, 2], channelLayout: Data([1, 2]), balance: 0.5, muted: false,
    baseline: [0.8], confirmed: [0.8], phase: .writeIntent, intended: [0.4])
try independentJournal.write(unrelated)
let acceptedHeld = try independentJournal.acknowledge(uid: "device-uid", observed: snapshot(value: 0.4), now: Date(), commit: { operation in try operation(); return true })
check(acceptedHeld, "held intent can be acknowledged without touching another active intent")
if case .record(let remaining) = try independentJournal.read() { check(remaining == unrelated, "unrelated pending intent is preserved") }
else { check(false, "unrelated pending intent must remain") }

let multipleDirectory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("voiceink-multiple-\(UUID().uuidString)")
defer { try? FileManager.default.removeItem(at: multipleDirectory) }
let multipleJournal = try AudioDuckingRecoveryJournal(directory: multipleDirectory)
let earlierIntent = record(phase: .writeIntent, intended: [0.2])
let laterIntent = record(phase: .writeIntent, intended: [0.3])
try multipleJournal.write(earlierIntent)
try multipleJournal.holdMissingDevice(earlierIntent)
try multipleJournal.write(laterIntent)
var completedCount = 0
while try multipleJournal.pendingRecovery(for: "device-uid") != nil {
    let completed = try multipleJournal.acknowledge(uid: "device-uid", observed: snapshot(value: 0.4), now: Date(), commit: { operation in try operation(); return true })
    check(completed, "each historical intent is durably archived")
    completedCount += 1
    check(completedCount <= 2, "recovery cannot loop over the same accepted intent")
}
let multipleBlocked = try multipleJournal.isAcknowledgedDeviceBlocked("device-uid")
check(completedCount == 2 && !multipleBlocked, "multiple intents for one UID can be resumed together")
let restartDirectory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("voiceink-relaunch-\(UUID().uuidString)")
defer { try? FileManager.default.removeItem(at: restartDirectory) }
func writeBeforeRelaunch(_ directory: URL, _ pending: AudioDuckingRecoveryRecord) throws {
    let owner = try AudioDuckingRecoveryJournal(directory: directory)
    try owner.write(pending)
}
func verifyAfterRelaunch(_ directory: URL, _ expected: AudioDuckingRecoveryRecord) throws {
    let nextOwner = try AudioDuckingRecoveryJournal(directory: directory)
    guard case .record(let loaded) = try nextOwner.read() else { check(false, "pending journal survives owner relaunch"); return }
    check(loaded == expected && loaded.decision(for: snapshot(value: 0.2)) == .ambiguous,
          "relaunch never treats observed target as confirmation")
    try nextOwner.holdMissingDevice(loaded)
    check(tryBlocked(nextOwner, "device-uid") && !tryBlocked(nextOwner, "other-device"),
          "relaunch holds only the missing device after evidence is durable")
}
func tryBlocked(_ journal: AudioDuckingRecoveryJournal, _ uid: String) -> Bool {
    (try? journal.isAcknowledgedDeviceBlocked(uid)) ?? true
}
try writeBeforeRelaunch(restartDirectory, pending)
try verifyAfterRelaunch(restartDirectory, pending)
print("AudioDucking recovery decisions passed")

// Explicit off/on recovery also covers confirmed records after a crash. This
// never infers continuous ownership or changes the original archived phase.
let confirmedResetDirectory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("voiceink-confirmed-reset-\(UUID().uuidString)")
defer { try? FileManager.default.removeItem(at: confirmedResetDirectory) }
let confirmedResetJournal = try AudioDuckingRecoveryJournal(directory: confirmedResetDirectory)
let crashedConfirmed = record(phase: .confirmed)
try confirmedResetJournal.write(crashedConfirmed)
let eligibleConfirmedReset = try confirmedResetJournal.pendingRecovery(for: "device-uid")?.1
check(eligibleConfirmedReset == crashedConfirmed,
      "confirmed crash evidence is eligible for explicit user reset")
let wrongUIDReset = try confirmedResetJournal.acknowledge(uid: "other-device", observed: snapshot(uid: "other-device", value: 0.24), now: Date(), reason: .userReenabledDucking, commit: { operation in try operation(); return true })
check(!wrongUIDReset, "explicit reset never clears another output's confirmed record")
let rejectedReset = try confirmedResetJournal.acknowledge(uid: "device-uid", observed: snapshot(value: 0.24), now: Date(), reason: .userReenabledDucking, commit: { _ in false })
check(!rejectedReset, "a live-write/event veto keeps confirmed recovery blocked")
if case .record(let remaining) = try confirmedResetJournal.read() {
    check(remaining == crashedConfirmed, "a rejected reset preserves the original confirmed evidence")
} else { check(false, "a rejected reset cannot erase confirmed evidence") }
let explicitReset = try confirmedResetJournal.acknowledge(uid: "device-uid", observed: snapshot(value: 0.24), now: Date(), reason: .userReenabledDucking, commit: { operation in try operation(); return true })
check(explicitReset, "the owner can explicitly reset confirmed recovery without an audio setter")
if case .absent = try confirmedResetJournal.read() {} else { check(false, "reset removes only the accepted active record") }
let archivedReceipt = confirmedResetDirectory.appendingPathComponent("accepted-\(crashedConfirmed.cycleID.uuidString).json")
let confirmedReceipt = try JSONDecoder().decode(AudioDuckingRecoveryJournal.Acknowledgment.self, from: Data(contentsOf: archivedReceipt))
check(confirmedReceipt.record == crashedConfirmed && confirmedReceipt.record.phase == .confirmed,
      "explicit reset preserves baseline, values and original phase rather than claiming restoration")
check(confirmedReceipt.reason == "user_reenabled_ducking" && confirmedReceipt.observedValues == [0.24],
      "reset archive records the actual action and observed volume")
let confirmedStillBlocked = try confirmedResetJournal.isAcknowledgedDeviceBlocked("device-uid")
check(!confirmedStillBlocked, "an accepted confirmed record no longer blocks a new session")
var freshLease = AudioDuckingLease()
let freshToken = freshLease.begin(UUID())
check(freshLease.activate(freshToken, values: [0.24], config: AudioDuckingConfiguration(mode: .duck), now: 0), "a fresh recording can start after reset")
check(freshLease.baseline == [0.24], "fresh recording retains current user volume, not the old crash baseline")

let heldConfirmed = record(phase: .confirmed)
try confirmedResetJournal.write(heldConfirmed)
try confirmedResetJournal.holdMissingDevice(heldConfirmed)
let heldReset = try confirmedResetJournal.acknowledge(uid: "device-uid", observed: snapshot(value: 0.24), now: Date(), reason: .userReenabledDucking, commit: { operation in try operation(); return true })
let heldStillBlocked = try confirmedResetJournal.isAcknowledgedDeviceBlocked("device-uid")
check(heldReset && !heldStillBlocked, "a connected output's held confirmed record can also be explicitly reset")
print("Confirmed crash recovery reset checks passed; no HAL writes")
