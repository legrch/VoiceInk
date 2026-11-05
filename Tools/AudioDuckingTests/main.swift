import Foundation

func check(_ condition: @autoclosure () -> Bool, _ description: String) {
    guard condition() else {
        fputs("FAIL: \(description)\n", stderr)
        exit(1)
    }
}

let legacy = AudioDuckingConfiguration.migrated(legacyMute: true)
check(legacy.mode == .mute && legacy.isValid, "legacy mute migration")
check(AudioDuckingConfiguration.migrated(legacyMute: false).mode == .unchanged, "legacy unchanged migration")
var config = AudioDuckingConfiguration(mode: .duck)
check(config.isValid, "default duck settings")
config.retainedPercent = .nan
check(!config.isValid, "nonfinite percentage rejected")
config.retainedPercent = 101
check(!config.isValid, "out of range percentage rejected")
config.retainedPercent = 20
config.fadeDownSeconds = .infinity
check(!config.isValid, "nonfinite time rejected")
config.fadeDownSeconds = -0.1
check(!config.isValid, "negative time rejected")
config.fadeDownSeconds = 10.1
check(!config.isValid, "excessive time rejected")
config.fadeDownSeconds = 1.5
let roundTrip = try JSONDecoder().decode(AudioDuckingConfiguration.self, from: JSONEncoder().encode(config))
check(roundTrip == config, "configuration round trip")
var future = config
future.version = 2
check(!future.isValid, "future configuration rejected")
let fade = AudioDuckingTransition(start: [0.6, 0.3], end: [0.12, 0.06], startTime: 10, duration: 2)!
let midpoint = fade.values(at: 11)
check(abs(midpoint[0] - 0.36) < 0.0001 && abs(midpoint[1] - 0.18) < 0.0001, "channels retain their ratio")
check(fade.values(at: 9) == [0.6, 0.3], "time clamped before start")
check(fade.values(at: 12) == [0.12, 0.06] && fade.isComplete(at: 12), "fade ends on target")
check(AudioDuckingTransition(start: [0.6], end: [0.1], startTime: 0, duration: 0)!.values(at: 0) == [0.1], "zero duration")
check(AudioDuckingTransition(start: [0.5], end: [], startTime: 0, duration: 1) == nil, "mismatched channels rejected")
print("AudioDucking pure configuration and transition checks passed")

var lease = AudioDuckingLease()
let first = UUID()
let second = UUID()
var leaseConfig = AudioDuckingConfiguration(mode: .duck)
leaseConfig.restoreDelaySeconds = 2
let firstToken = lease.begin(first)
check(lease.activate(firstToken, values: [0.6], config: leaseConfig, now: 0), "activate first session")
lease.confirm([0.12], token: firstToken)
lease.end(firstToken, config: leaseConfig, now: 4)
lease.end(firstToken, config: leaseConfig, now: 5)
check(lease.restoreDeadline == 6, "duplicate stop preserves deadline")
check(!lease.prepareRestore(firstToken, current: [0.12], config: leaseConfig, now: 5), "restore waits for deadline")
check(lease.prepareRestore(firstToken, current: [0.12], config: leaseConfig, now: 6), "restore starts at deadline")
let secondToken = lease.begin(second)
check(lease.baseline == [0.6], "new session inherits baseline")
lease.end(secondToken, config: leaseConfig, now: 7)
check(lease.restoreDeadline == 9, "new session starts its own restore delay")
lease.confirm([0.4], token: firstToken)
lease.finishRestore(token: firstToken)
lease.end(firstToken, config: leaseConfig, now: 8)
lease.invalidate(token: firstToken)
check(lease.baseline == [0.6] && lease.lastConfirmed == [0.12] && lease.restoreDeadline == 9,
      "stale first-session callbacks do not modify inherited lease")
check(lease.prepareRestore(secondToken, current: [0.12], config: leaseConfig, now: 9), "inherited lease restores even without activation")
check(lease.transition?.end == [0.6], "restoration uses original baseline")
lease.finishRestore(token: secondToken)
check(lease.baseline == nil, "current session may finish restore")
lease.confirm([0.4], token: secondToken)
check(lease.lastConfirmed == nil, "completion retires token")
lease.invalidate(token: secondToken)
check(!lease.prepareRestore(secondToken, current: [0.12], config: leaseConfig, now: 10), "invalidation suppresses future restoration")
check(!lease.activate(secondToken, values: [0.6], config: leaseConfig, now: 10), "invalidation suppresses delayed activation")
print("AudioDucking pure lease checks passed")

let existing = AudioDuckingConfiguration(mode: .duck)
var imported = existing
imported.retainedPercent = 35
check(AudioDuckingBackupPolicy.decide(payload: .valid(imported), legacyMute: true, current: existing) == .apply(imported), "valid payload wins over legacy")
check(AudioDuckingBackupPolicy.decide(payload: .invalid, legacyMute: true, current: existing) == .reject, "invalid payload never falls back to legacy")
check(AudioDuckingBackupPolicy.decide(payload: .absent, legacyMute: nil, current: existing) == .preserve, "absent audio fields preserve settings")
var legacyOff = existing
legacyOff.mode = .unchanged
check(AudioDuckingBackupPolicy.decide(payload: .absent, legacyMute: false, current: existing) == .apply(legacyOff), "legacy import changes mode even after migration")
var invalidImport = imported
invalidImport.version = 2
check(AudioDuckingBackupPolicy.decide(payload: .valid(invalidImport), legacyMute: true, current: existing) == .reject, "unknown payload version rejected")
print("AudioDucking pure backup precedence checks passed")

var shortLease = AudioDuckingLease()
let shortSession = UUID()
let shortToken = shortLease.begin(shortSession)
shortLease.end(shortToken, config: existing, now: 0.1)
check(!shortLease.activate(shortToken, values: [0.6], config: existing, now: 0.22), "stop before delayed start prevents late ducking")
print("AudioDucking short-session suppression check passed")

var invalidatedLease = AudioDuckingLease()
let invalidatedToken = invalidatedLease.begin(UUID())
invalidatedLease.invalidate(token: invalidatedToken)
check(invalidatedLease.suppressed, "current invalidation suppresses session")
check(!invalidatedLease.activate(invalidatedToken, values: [0.6], config: existing, now: 0.22), "invalidated token cannot activate")

var ownership = AudioDuckingControlOwnership(baseline: [0.6, 0.3])!
ownership.recordWrite(index: 0, before: 0.6, reportedSuccess: true, readback: 0.125)
ownership.recordWrite(index: 1, before: 0.3, reportedSuccess: false, readback: nil)
check(ownership.states == [.owned(lastConfirmed: 0.125), .uncertain], "per-channel confirmed and uncertain effects")
check(ownership.ownedRestoreTarget(index: 0, current: 0.125) == 0.6, "quantized owned control can restore")
check(ownership.ownedRestoreTarget(index: 1, current: 0.3) == nil, "uncertain channel cannot restore")
check(ownership.ownedRestoreTarget(index: 0, current: 0.2) == nil, "manual change revokes restoration")
check(ownership.states[0] == .relinquished, "manual change revokes ownership")
var noChange = AudioDuckingControlOwnership(baseline: [0.6])!
noChange.recordWrite(index: 0, before: 0.6, reportedSuccess: true, readback: 0.6)
check(noChange.ownedRestoreTarget(index: 0, current: 0.6) == nil, "unchanged control creates no ownership")
print("AudioDucking per-control ownership checks passed")

final class FakeOutput: AudioDuckingOutput {
    var requiresWriteNotification = false
    var devices: [UInt32: AudioDuckingOutputSnapshot] = [:]
    var selected: UInt32 = 1
    var writes: [(UInt32, UInt32, Float)] = []
    var failElement: UInt32?
    var coupled = false
    var otherChannelULPDrift = false
    var quantizationStep: Float?
    var predictsQuantization = true
    var roundingULP = false
    var roundingDelta: Float = 0
    var hideDefault = false
    var deferWrites = false
    var pendingWrite: (UInt32, UInt32, Float)?
    var onWrite: (() -> Void)?
    var beforeAdapterCheck: (() -> Void)?
    var beforeOwnedCheck: (() -> Void)?
    var onReadDefault: (() -> Void)?
    func readDefault() -> AudioDuckingOutputSnapshot? {
        let snapshot = hideDefault ? nil : devices[selected]
        onReadDefault?()
        return snapshot
    }
    func readNamed(deviceID: UInt32) -> AudioDuckingOutputSnapshot? { devices[deviceID] }
    func canonicalTarget(deviceID: UInt32, element: UInt32, value: Float) -> Float? {
        guard predictsQuantization, let step = quantizationStep else { return value }
        return (value / step).rounded() * step
    }
    func writeDefault(deviceID: UInt32, element: UInt32, value: Float, expected: AudioDuckingOutputSnapshot) -> AudioDuckingWriteResult {
        beforeAdapterCheck?()
        guard deviceID == selected, devices[deviceID] == expected else { return .notAttempted }
        return .attempted(write(deviceID: deviceID, element: element, value: value))
    }
    func writeOwnedDevice(deviceID: UInt32, element: UInt32, value: Float, expected: AudioDuckingOutputSnapshot) -> AudioDuckingWriteResult {
        beforeOwnedCheck?()
        guard devices[deviceID] == expected else { return .notAttempted }
        return .attempted(write(deviceID: deviceID, element: element, value: value))
    }
    private func write(deviceID: UInt32, element: UInt32, value: Float) -> Bool {
        writes.append((deviceID, element, value))
        onWrite?()
        guard element != failElement, let old = devices[deviceID], let index = old.elements.firstIndex(of: element) else { return false }
        if deferWrites { pendingWrite = (deviceID, element, value); return true }
        var values = old.values
        if let step = quantizationStep {
            values[index] = (value / step).rounded() * step
        } else {
            values[index] = roundingULP ? value.nextUp : value + roundingDelta
        }
        if coupled && values.count > 1 && index == 0 { values[1] = value }
        devices[deviceID] = AudioDuckingOutputSnapshot(deviceID: old.deviceID, uid: old.uid, elements: old.elements, values: values, muted: old.muted, control: old.control, stereoChannels: old.stereoChannels, balance: old.balance, channelLayout: old.channelLayout)
        return true
    }
    func deliverPendingWrite() {
        guard let pending = pendingWrite, let old = devices[pending.0],
              let index = old.elements.firstIndex(of: pending.1) else { return }
        var values = old.values
        values[index] = pending.2
        if coupled && values.count > 1 && index == 0 { values[1] = pending.2 }
        if otherChannelULPDrift { for other in values.indices where other != index { values[other] = values[other].nextUp } }
        devices[pending.0] = AudioDuckingOutputSnapshot(deviceID: old.deviceID, uid: old.uid, elements: old.elements, values: values, muted: old.muted, control: old.control, stereoChannels: old.stereoChannels, balance: old.balance, channelLayout: old.channelLayout)
        pendingWrite = nil
    }
}
func makeOutput(_ values: [Float] = [0.6, 0.3]) -> FakeOutput {
    let output = FakeOutput()
    output.devices[1] = AudioDuckingOutputSnapshot(deviceID: 1, uid: "one", elements: Array(1...UInt32(values.count)), values: values, muted: false)
    return output
}
var runtimeConfig = AudioDuckingConfiguration(mode: .duck)
runtimeConfig.fadeDownSeconds = 0
runtimeConfig.fadeUpSeconds = 0
runtimeConfig.restoreDelaySeconds = 2
let fake = makeOutput()
let runtime = AudioDuckingRuntime(output: fake)
let runtimeA = runtime.begin(sessionID: UUID(), desired: runtimeConfig)!
runtime.activate(token: runtimeA, now: 1)
check(abs(fake.devices[1]!.values[0] - 0.12) < 0.0001 && abs(fake.devices[1]!.values[1] - 0.06) < 0.0001, "runtime ducks original channels")
runtime.end(token: runtimeA, now: 2)
runtime.end(token: runtimeA, now: 3)
check(runtime.lease.restoreDeadline == 4, "runtime duplicate stop preserves deadline")
let runtimeB = runtime.begin(sessionID: UUID(), desired: AudioDuckingConfiguration(mode: .unchanged))!
check(runtime.effectiveConfiguration == runtimeConfig, "desired change waits for inherited ownership cycle")
runtime.end(token: runtimeB, now: 3)
runtime.tick(token: runtimeA, now: 10)
check(runtime.lease.baseline == [0.6, 0.3], "stale tick cannot finish new session")
runtime.tick(token: runtimeB, now: 5)
check(fake.devices[1]!.values == [0.6, 0.3] && runtime.status == .idle, "inherited short session restores baseline")
let manual = makeOutput([0.6])
let manualRuntime = AudioDuckingRuntime(output: manual)
let manualToken = manualRuntime.begin(sessionID: UUID(), desired: runtimeConfig)!
manual.devices[1] = AudioDuckingOutputSnapshot(deviceID: 1, uid: "one", elements: [1], values: [0.4], muted: false)
manualRuntime.activate(token: manualToken, now: 1)
check(manual.writes.isEmpty, "manual change during grace suppresses writes")
let route = makeOutput([0.6])
route.devices[2] = AudioDuckingOutputSnapshot(deviceID: 2, uid: "two", elements: [1], values: [0.8], muted: false)
let routeRuntime = AudioDuckingRuntime(output: route)
let routeToken = routeRuntime.begin(sessionID: UUID(), desired: runtimeConfig)!
routeRuntime.activate(token: routeToken, now: 0)
route.selected = 2
routeRuntime.invalidate(token: routeToken)
check(route.devices[1]!.values == [0.6] && route.devices[2]!.values == [0.8], "route change cleans only owned old output")
let beforeReconnect = route.writes.count
route.selected = 1
routeRuntime.tick(token: routeToken, now: 10)
check(route.writes.count == beforeReconnect, "reconnect cannot restore old lease again")
print("AudioDucking coordinator fake-output checks passed")

let partial = makeOutput()
partial.failElement = 2
let partialRuntime = AudioDuckingRuntime(output: partial)
let partialToken = partialRuntime.begin(sessionID: UUID(), desired: runtimeConfig)!
partialRuntime.activate(token: partialToken, now: 0)
check(partial.devices[1]!.values == [0.6, 0.3], "partial failure cleans only confirmed changed channel")
check(partialRuntime.status == .incomplete, "uncertain channel is reported incomplete")
let partialWrites = partial.writes.count
partialRuntime.tick(token: partialToken, now: 10)
check(partial.writes.count == partialWrites, "failed session cannot write again")
let grace = makeOutput([0.6])
let graceRuntime = AudioDuckingRuntime(output: grace)
let graceToken = graceRuntime.begin(sessionID: UUID(), desired: runtimeConfig)!
graceRuntime.invalidate(token: graceToken)
graceRuntime.activate(token: graceToken, now: 1)
check(grace.writes.isEmpty, "route invalidation before grace suppresses delayed activation")
print("AudioDucking partial-write and grace checks passed")

var normalWritesAllowed = true
let boundary = makeOutput()
let boundaryRuntime = AudioDuckingRuntime(output: boundary, normalWriteAllowed: { _ in normalWritesAllowed })
let boundaryToken = boundaryRuntime.begin(sessionID: UUID(), desired: runtimeConfig)!
boundary.onWrite = { normalWritesAllowed = false }
boundaryRuntime.activate(token: boundaryToken, now: 0)
check(boundary.writes.count == 1, "invalidation latch stops later normal channel writes")
boundary.onWrite = nil
boundaryRuntime.invalidate(token: boundaryToken)
check(boundary.devices[1]!.values == [0.6, 0.3], "latched session cleans previously owned channel")
print("AudioDucking invalidation boundary check passed")

var fullVolumeConfig = runtimeConfig
fullVolumeConfig.retainedPercent = 100
let full = makeOutput([0.6])
let fullRuntime = AudioDuckingRuntime(output: full)
let fullToken = fullRuntime.begin(sessionID: UUID(), desired: fullVolumeConfig)!
fullRuntime.activate(token: fullToken, now: 0)
fullRuntime.end(token: fullToken, now: 0)
fullRuntime.tick(token: fullToken, now: 2)
check(full.writes.isEmpty && fullRuntime.status == .idle, "100 percent creates no hardware effects")
let silent = makeOutput([0])
let silentRuntime = AudioDuckingRuntime(output: silent)
let silentToken = silentRuntime.begin(sessionID: UUID(), desired: runtimeConfig)!
silentRuntime.activate(token: silentToken, now: 0)
silentRuntime.end(token: silentToken, now: 0)
silentRuntime.tick(token: silentToken, now: 2)
check(silent.writes.isEmpty && silentRuntime.status == .idle, "zero baseline creates no hardware effects")

let eventLatch = AudioDuckingEventLatch()
let latchEpoch = eventLatch.currentEpoch()
var latchLease = AudioDuckingLease()
let latchA = latchLease.begin(UUID())
check(eventLatch.admit(latchA, observedEpoch: latchEpoch) && eventLatch.permits(latchA), "latch admits current epoch")
check(eventLatch.invalidate() == latchA && !eventLatch.permits(latchA), "event immediately suppresses admitted token")
check(eventLatch.pendingInvalidation() == latchA, "pending invalidation is visible before cleanup dispatch")
let latchB = latchLease.begin(UUID())
check(!eventLatch.admit(latchB, observedEpoch: latchEpoch), "event during begin rejects stale snapshot")
check(eventLatch.admit(latchB, observedEpoch: eventLatch.currentEpoch()), "new epoch admits new session")
eventLatch.clear(latchA)
check(eventLatch.pendingInvalidation() == nil, "newly admitted epoch has no stale pending invalidation")
check(eventLatch.permits(latchB), "old cleanup cannot clear new session latch")
check(!eventLatch.invalidate(ifCurrent: latchA) && eventLatch.permits(latchB), "old device callback cannot invalidate new session")
check(eventLatch.invalidate(ifCurrent: latchB) && !eventLatch.permits(latchB), "current device callback invalidates session")
let acknowledgmentEpoch = eventLatch.currentEpoch()
let committed = eventLatch.performIfCurrent(acknowledgmentEpoch) { true }
check(committed == true, "unchanged event epoch allows atomic acknowledgment commit")
_ = eventLatch.invalidate()
var staleCommitRan = false
let staleCommit = eventLatch.performIfCurrent(acknowledgmentEpoch) { staleCommitRan = true; return true }
check(staleCommit == nil && !staleCommitRan, "a system event prevents an acknowledgment commit from an old epoch")
print("AudioDucking event latch checks passed")

struct BackupFixture: Codable {
    @AudioDuckingBackupField var audioDucking: AudioDuckingBackupPayload = .absent
    var isSystemMuteEnabled: Bool?
}
func backupFixture(_ json: String) throws -> BackupFixture {
    try JSONDecoder().decode(BackupFixture.self, from: Data(json.utf8))
}
let absentFixture = try backupFixture("{\"isSystemMuteEnabled\":true}")
if case .absent = absentFixture.audioDucking {} else { check(false, "missing JSON payload is absent") }
for json in ["{\"audioDucking\":null}", "{\"audioDucking\":42}", "{\"audioDucking\":{\"version\":99,\"mode\":\"duck\"}}"] {
    let fixture = try backupFixture(json)
    if case .invalid = fixture.audioDucking {} else { check(false, "present malformed JSON payload is invalid") }
}
let payloadFixture = BackupFixture(audioDucking: .valid(imported), isSystemMuteEnabled: true)
let fixtureBytes = try JSONEncoder().encode(payloadFixture)
let decodedFixture = try JSONDecoder().decode(BackupFixture.self, from: fixtureBytes)
if case .valid(let decoded) = decodedFixture.audioDucking { check(decoded == imported, "JSON payload round trip") }
else { check(false, "valid JSON payload remains valid") }
let absentBytes = try JSONEncoder().encode(absentFixture)
check(!String(decoding: absentBytes, as: UTF8.self).contains("audioDucking"), "absent payload is omitted on export")
print("AudioDucking backup JSON presence checks passed")

check(AudioDelay.nanoseconds(1.5) == 1_500_000_000, "ordinary legacy delay is representable")
check(AudioDelay.nanoseconds(-1) == nil && AudioDelay.nanoseconds(1e20) == nil && AudioDelay.nanoseconds(.nan) == nil,
      "invalid legacy delays cannot reach integer conversion")
check(AudioDelay.restorationNanoseconds(-1) == 0 && AudioDelay.restorationNanoseconds(1e20) == 0,
      "invalid persisted delays do not prevent restoration")

let coupledOutput = makeOutput()
coupledOutput.coupled = true
let coupledRuntime = AudioDuckingRuntime(output: coupledOutput)
let coupledToken = coupledRuntime.begin(sessionID: UUID(), desired: runtimeConfig)!
coupledRuntime.activate(token: coupledToken, now: 0)
check(coupledRuntime.status == .incomplete, "coupled channel change reports incomplete restoration")
check(!coupledOutput.writes.contains(where: { $0.1 == 2 }), "coupled unowned channel is never directly restored")
check(coupledOutput.writes.count == 1 && coupledOutput.devices[1]!.values[1] <= 0.3,
      "coupled cleanup never raises an unowned channel")

let unreadable = makeOutput([0.6])
let unreadableRuntime = AudioDuckingRuntime(output: unreadable)
let unreadableToken = unreadableRuntime.begin(sessionID: UUID(), desired: runtimeConfig)!
unreadable.onWrite = { unreadable.hideDefault = true }
unreadableRuntime.activate(token: unreadableToken, now: 0)
check(unreadableRuntime.status == .incomplete && unreadable.writes.count == 1, "unreadable post-write result is uncertain without setter retry")
unreadable.hideDefault = false
unreadableRuntime.tick(token: unreadableToken, now: 20)
check(unreadable.writes.count == 1, "uncertain result is not retried on reconnect")
let disconnected = makeOutput([0.6])
let disconnectedRuntime = AudioDuckingRuntime(output: disconnected)
let disconnectToken = disconnectedRuntime.begin(sessionID: UUID(), desired: runtimeConfig)!
disconnectedRuntime.activate(token: disconnectToken, now: 0)
let quietSnapshot = disconnected.devices.removeValue(forKey: 1)!
disconnectedRuntime.invalidate(token: disconnectToken)
check(disconnectedRuntime.status == .incomplete, "unavailable owned output reports incomplete restoration")
let countBeforeReconnect = disconnected.writes.count
disconnected.devices[1] = quietSnapshot
disconnectedRuntime.tick(token: disconnectToken, now: 10)
check(disconnected.writes.count == countBeforeReconnect, "reconnected device receives no automatic restoration")

let delayed = makeOutput([0.6])
delayed.deferWrites = true
let delayedRuntime = AudioDuckingRuntime(output: delayed)
let delayedToken = delayedRuntime.begin(sessionID: UUID(), desired: runtimeConfig)!
delayedRuntime.activate(token: delayedToken, now: 0)
check(delayedRuntime.status == .incomplete, "unchanged immediate readback is treated as unconfirmed")
check(delayedRuntime.begin(sessionID: UUID(), desired: runtimeConfig) == nil,
      "an unresolved hardware write must block a new ducking session")
delayedRuntime.end(token: delayedToken, now: 1)
delayed.deliverPendingWrite()
delayedRuntime.tick(token: delayedToken, now: 5)
check(delayed.writes.count == 1, "late asynchronous effect cannot trigger a blind restore")

let notified = makeOutput([0.6])
notified.requiresWriteNotification = true
notified.deferWrites = true
let notifiedRuntime = AudioDuckingRuntime(output: notified)
let notifiedToken = notifiedRuntime.begin(sessionID: UUID(), desired: runtimeConfig)!
notifiedRuntime.activate(token: notifiedToken, now: 0)
check(notifiedRuntime.hasPendingWrite, "asynchronous write waits for notification")
let staleObservation = notified.devices[1]!
notifiedRuntime.volumeChanged(token: notifiedToken, now: 0.1)
check(notifiedRuntime.hasPendingWrite && notifiedRuntime.status == .active,
      "stale notification with unchanged value does not cancel pending write")
notifiedRuntime.end(token: notifiedToken, now: 1)
notified.deliverPendingWrite()
notifiedRuntime.volumeChanged(token: notifiedToken, now: 1.05, observed: staleObservation)
check(notifiedRuntime.hasPendingWrite, "old notification is not attributed a newer readback")
notifiedRuntime.volumeChanged(token: notifiedToken, now: 1.1)
check(notifiedRuntime.status == .restoring, "stop retains restoration after asynchronous acknowledgment")
notifiedRuntime.tick(token: notifiedToken, now: 5)
if notifiedRuntime.hasPendingWrite {
    notified.deliverPendingWrite()
    notifiedRuntime.volumeChanged(token: notifiedToken, now: 5.1)
}
check(notifiedRuntime.status == .idle && notified.devices[1]!.values == [0.6], "acknowledged delayed write restores baseline")

// Channel-only adapters must confirm each asynchronous setter independently.
let stereoAsync = makeOutput([0.6, 0.3])
stereoAsync.devices[1] = AudioDuckingOutputSnapshot(deviceID: 1, uid: "one", elements: [1, 2], values: [0.6, 0.3], muted: false, control: .physicalChannels, stereoChannels: [1, 2], channelLayout: Data([1]))
stereoAsync.requiresWriteNotification = true
stereoAsync.deferWrites = true
let stereoDirectory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("voiceink-stereo-\(UUID().uuidString)")
let stereoJournal = try AudioDuckingRecoveryJournal(directory: stereoDirectory)
let stereoAsyncRuntime = AudioDuckingRuntime(output: stereoAsync, journal: stereoJournal)
let stereoAsyncToken = stereoAsyncRuntime.begin(sessionID: UUID(), desired: runtimeConfig)!
stereoAsyncRuntime.activate(token: stereoAsyncToken, now: 0)
check(stereoAsync.writes.count == 1 && stereoAsync.writes[0].1 == 1,
      "the second stereo channel waits for the first notification")
stereoAsync.deliverPendingWrite()
stereoAsyncRuntime.volumeChanged(token: stereoAsyncToken, now: 0.1)
check(stereoAsync.writes.count == 2 && stereoAsync.writes[1].1 == 2,
      "the second stereo channel is issued only after first acknowledgment")
if case .record(let entry) = try stereoJournal.read() {
    check(entry.phase == .writeIntent && abs(entry.confirmed[0] - 0.12) < 0.0001 && entry.confirmed[1] == 0.3,
          "first channel is durably confirmed while second remains pending")
} else { check(false, "stereo pending state is journaled") }
stereoAsync.deliverPendingWrite()
stereoAsyncRuntime.volumeChanged(token: stereoAsyncToken, now: 0.2)
check(abs(stereoAsync.devices[1]!.values[0] - 0.12) < 0.0001 && abs(stereoAsync.devices[1]!.values[1] - 0.06) < 0.0001,
      "independently acknowledged stereo channels retain their baseline ratio")
stereoAsyncRuntime.end(token: stereoAsyncToken, now: 1)
stereoAsyncRuntime.tick(token: stereoAsyncToken, now: 4)
stereoAsync.deliverPendingWrite()
stereoAsyncRuntime.volumeChanged(token: stereoAsyncToken, now: 4.1)
stereoAsync.deliverPendingWrite()
stereoAsyncRuntime.volumeChanged(token: stereoAsyncToken, now: 4.2)
check(stereoAsyncRuntime.status == .idle && stereoAsync.devices[1]!.values == [0.6, 0.3],
      "stereo recovery independently confirms both baseline values")
if case .absent = try stereoJournal.read() {} else { check(false, "stereo journal clears only after both restores") }
try FileManager.default.removeItem(at: stereoDirectory)

let driftedStereo = makeOutput([0.6, 0.3])
driftedStereo.requiresWriteNotification = true
driftedStereo.deferWrites = true
driftedStereo.otherChannelULPDrift = true
let driftedRuntime = AudioDuckingRuntime(output: driftedStereo)
let driftedToken = driftedRuntime.begin(sessionID: UUID(), desired: runtimeConfig)!
driftedRuntime.activate(token: driftedToken, now: 0)
for step in 1...2 {
    driftedStereo.deliverPendingWrite()
    driftedRuntime.volumeChanged(token: driftedToken, now: Double(step) * 0.1)
}
check(!driftedRuntime.isQuarantined && driftedStereo.writes.count == 2,
      "a one-ULP change in the other channel does not falsely quarantine stereo")
driftedRuntime.end(token: driftedToken, now: 1)
driftedRuntime.tick(token: driftedToken, now: 4)
for step in 1...2 {
    driftedStereo.deliverPendingWrite()
    driftedRuntime.volumeChanged(token: driftedToken, now: 4 + Double(step) * 0.1)
}
check(driftedRuntime.status == .idle && AudioDuckingOutputSnapshot.levelsMatch(driftedStereo.devices[1]!.values, [0.6, 0.3]),
      "other-channel floating point drift still restores the original stereo baseline")

let stereoCoupled = makeOutput([0.6, 0.3])
stereoCoupled.devices[1] = AudioDuckingOutputSnapshot(deviceID: 1, uid: "one", elements: [1, 2], values: [0.6, 0.3], muted: false, control: .physicalChannels, stereoChannels: [1, 2], channelLayout: Data([1]))
stereoCoupled.requiresWriteNotification = true
stereoCoupled.deferWrites = true
stereoCoupled.coupled = true
let stereoCoupledRuntime = AudioDuckingRuntime(output: stereoCoupled)
let stereoCoupledToken = stereoCoupledRuntime.begin(sessionID: UUID(), desired: runtimeConfig)!
stereoCoupledRuntime.activate(token: stereoCoupledToken, now: 0)
stereoCoupled.deliverPendingWrite()
stereoCoupledRuntime.volumeChanged(token: stereoCoupledToken, now: 0.1)
check(stereoCoupledRuntime.isQuarantined && stereoCoupled.writes.count == 1,
      "coupled stereo hardware is quarantined without an unowned second write")

let stereoPending = makeOutput([0.6, 0.3])
stereoPending.devices[1] = AudioDuckingOutputSnapshot(deviceID: 1, uid: "one", elements: [1, 2], values: [0.6, 0.3], muted: false, control: .physicalChannels, stereoChannels: [1, 2], channelLayout: Data([1]))
stereoPending.requiresWriteNotification = true
stereoPending.deferWrites = true
let stereoPendingRuntime = AudioDuckingRuntime(output: stereoPending)
let stereoPendingToken = stereoPendingRuntime.begin(sessionID: UUID(), desired: runtimeConfig)!
stereoPendingRuntime.activate(token: stereoPendingToken, now: 0)
stereoPendingRuntime.invalidate(token: stereoPendingToken)
stereoPending.deliverPendingWrite()
stereoPendingRuntime.volumeChanged(token: stereoPendingToken, now: 0.1)
check(stereoPendingRuntime.isQuarantined && stereoPending.writes.count == 1,
      "a route event while a stereo write is pending suppresses all later channel writes")

let lost = makeOutput([0.6])
lost.requiresWriteNotification = true
lost.deferWrites = true
let lostRuntime = AudioDuckingRuntime(output: lost)
let lostToken = lostRuntime.begin(sessionID: UUID(), desired: runtimeConfig)!
lostRuntime.activate(token: lostToken, now: 0)
lostRuntime.invalidate(token: lostToken)
lost.deliverPendingWrite()
lostRuntime.volumeChanged(token: lostToken, now: 1)
check(lost.writes.count == 1 && lostRuntime.status == .incomplete, "invalidation suppresses writes after delayed completion")

let invalidatedOwned = makeOutput([0.6])
invalidatedOwned.requiresWriteNotification = true
let invalidatedRuntime = AudioDuckingRuntime(output: invalidatedOwned)
let invalidatedRuntimeToken = invalidatedRuntime.begin(sessionID: UUID(), desired: runtimeConfig)!
invalidatedRuntime.activate(token: invalidatedRuntimeToken, now: 0)
invalidatedRuntime.volumeChanged(token: invalidatedRuntimeToken, now: 0.1)
let ownedWrites = invalidatedOwned.writes.count
invalidatedRuntime.invalidate(token: invalidatedRuntimeToken)
check(invalidatedOwned.writes.count == ownedWrites && invalidatedRuntime.status == .incomplete,
      "invalidated async output does not receive an unacknowledged cleanup write")
check(!invalidatedRuntime.isQuarantined,
      "an acknowledged write with abandoned restoration is not an unresolved setter")

let unexpected = makeOutput([0.6])
unexpected.requiresWriteNotification = true
unexpected.deferWrites = true
let unexpectedRuntime = AudioDuckingRuntime(output: unexpected)
let unexpectedToken = unexpectedRuntime.begin(sessionID: UUID(), desired: runtimeConfig)!
unexpectedRuntime.activate(token: unexpectedToken, now: 0)
unexpected.devices[1] = AudioDuckingOutputSnapshot(deviceID: 1, uid: "one", elements: [1], values: [0.45], muted: false)
unexpectedRuntime.volumeChanged(token: unexpectedToken, now: 0.1, observed: unexpected.devices[1])
check(unexpectedRuntime.isQuarantined && unexpectedRuntime.status == .incomplete,
      "a different volume observed during a pending write enters quarantine")
check(unexpectedRuntime.failureReason == "notification_unexpected_value", "unexpected readback reports diagnostic reason")
check(unexpectedRuntime.failureLevels?.observed == 0.45 && unexpectedRuntime.failureLevels?.before == 0.6,
      "unexpected readback records the original and observed scalars")
unexpectedRuntime.end(token: unexpectedToken, now: 1)
unexpected.deliverPendingWrite()
unexpectedRuntime.tick(token: unexpectedToken, now: 4)
check(unexpected.writes.count == 1, "a late write after an unexpected adjustment does not schedule restoration")

let noNotification = makeOutput([0.6])
noNotification.requiresWriteNotification = true
noNotification.deferWrites = true
let noNotificationRuntime = AudioDuckingRuntime(output: noNotification)
let noNotificationToken = noNotificationRuntime.begin(sessionID: UUID(), desired: runtimeConfig)!
noNotificationRuntime.activate(token: noNotificationToken, now: 0)
noNotificationRuntime.tick(token: noNotificationToken, now: 2.1)
check(noNotificationRuntime.isQuarantined && noNotificationRuntime.status == .incomplete,
      "a missing notification times out into quarantine")
check(noNotificationRuntime.failureReason == "notification_timeout", "notification timeout reports diagnostic reason")

let virtualOutput = makeOutput([0.6])
virtualOutput.requiresWriteNotification = true
virtualOutput.devices[1] = AudioDuckingOutputSnapshot(deviceID: 1, uid: "one", elements: [0], values: [0.6], muted: false, control: .virtualMain, stereoChannels: [1, 2], balance: 0.5)
let virtualRuntime = AudioDuckingRuntime(output: virtualOutput)
let virtualToken = virtualRuntime.begin(sessionID: UUID(), desired: runtimeConfig)!
virtualRuntime.activate(token: virtualToken, now: 0)
virtualRuntime.volumeChanged(token: virtualToken, now: 0.1)
virtualRuntime.end(token: virtualToken, now: 1)
virtualRuntime.tick(token: virtualToken, now: 4)
virtualRuntime.volumeChanged(token: virtualToken, now: 4.1)
check(virtualRuntime.status == .idle && abs(virtualOutput.devices[1]!.values[0] - 0.6) < 0.000001,
      "virtual main control ducks and restores through acknowledged writes")
check(virtualOutput.writes.allSatisfy({ $0.1 == 0 }), "virtual main writes only element zero")

let liveLevel = makeOutput([0.6])
let liveRuntime = AudioDuckingRuntime(output: liveLevel)
let liveToken = liveRuntime.begin(sessionID: UUID(), desired: runtimeConfig)!
liveRuntime.activate(token: liveToken, now: 0)
liveRuntime.updateRetainedPercent(50, token: liveToken, now: 0.5)
check(abs(liveLevel.devices[1]!.values[0] - 0.3) < 0.000001, "live level uses the original baseline")
liveRuntime.end(token: liveToken, now: 1)
liveRuntime.tick(token: liveToken, now: 4)
check(abs(liveLevel.devices[1]!.values[0] - 0.6) < 0.000001, "live level adjustment preserves the restoration baseline")

var deviceConfig = runtimeConfig
deviceConfig.setRetainedPercent(50, for: "one")
let deviceOutput = makeOutput([0.6])
let deviceRuntime = AudioDuckingRuntime(output: deviceOutput)
let deviceToken = deviceRuntime.begin(sessionID: UUID(), desired: deviceConfig)!
deviceRuntime.activate(token: deviceToken, now: 0)
check(abs(deviceOutput.devices[1]!.values[0] - 0.3) < 0.000001,
      "the captured output UID selects its saved percentage")

let manualDuringLive = makeOutput([0.6])
let manualDuringLiveRuntime = AudioDuckingRuntime(output: manualDuringLive)
let manualDuringLiveToken = manualDuringLiveRuntime.begin(sessionID: UUID(), desired: runtimeConfig)!
manualDuringLiveRuntime.activate(token: manualDuringLiveToken, now: 0)
manualDuringLive.devices[1] = AudioDuckingOutputSnapshot(deviceID: 1, uid: "one", elements: [1], values: [0.4], muted: false)
manualDuringLiveRuntime.updateRetainedPercent(50, token: manualDuringLiveToken, now: 0.5)
manualDuringLiveRuntime.tick(token: manualDuringLiveToken, now: 0.6)
manualDuringLiveRuntime.end(token: manualDuringLiveToken, now: 1)
check(manualDuringLive.devices[1]!.values == [0.4], "live setting changes do not overwrite manual system volume")

let delayedLevel = makeOutput([0.6])
delayedLevel.requiresWriteNotification = true
delayedLevel.deferWrites = true
let delayedLevelRuntime = AudioDuckingRuntime(output: delayedLevel)
let delayedLevelToken = delayedLevelRuntime.begin(sessionID: UUID(), desired: runtimeConfig)!
delayedLevelRuntime.activate(token: delayedLevelToken, now: 0)
delayedLevelRuntime.updateRetainedPercent(30, token: delayedLevelToken, now: 0.1)
delayedLevelRuntime.updateRetainedPercent(40, token: delayedLevelToken, now: 0.2)
delayedLevel.deliverPendingWrite()
delayedLevelRuntime.volumeChanged(token: delayedLevelToken, now: 0.3)
delayedLevel.deliverPendingWrite()
delayedLevelRuntime.volumeChanged(token: delayedLevelToken, now: 0.4)
check(abs(delayedLevel.devices[1]!.values[0] - 0.24) < 0.000001,
      "the latest live level is applied after the pending write")
delayedLevelRuntime.end(token: delayedLevelToken, now: 1)
delayedLevelRuntime.tick(token: delayedLevelToken, now: 4)
delayedLevel.deliverPendingWrite()
delayedLevelRuntime.volumeChanged(token: delayedLevelToken, now: 4.1)
check(abs(delayedLevel.devices[1]!.values[0] - 0.6) < 0.000001,
      "pending live changes still restore the original baseline")

let journalDirectory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("voiceink-runtime-journal-\(UUID().uuidString)")
let runtimeJournal = try AudioDuckingRecoveryJournal(directory: journalDirectory)
let journalOutput = makeOutput([0.6])
journalOutput.requiresWriteNotification = true
journalOutput.deferWrites = true
let journalRuntime = AudioDuckingRuntime(output: journalOutput, journal: runtimeJournal)
let journalToken = journalRuntime.begin(sessionID: UUID(), desired: runtimeConfig)!
journalRuntime.activate(token: journalToken, now: 0)
if case .record(let entry) = try runtimeJournal.read() {
    check(entry.phase == .writeIntent && entry.baseline == [0.6], "intent is durable before setter acknowledgement")
} else { check(false, "pending write has a journal record") }
journalOutput.deliverPendingWrite()
journalRuntime.volumeChanged(token: journalToken, now: 0.1)
if case .record(let entry) = try runtimeJournal.read() {
    check(entry.phase == .confirmed && entry.confirmed == journalOutput.devices[1]!.values, "acknowledged write is journaled")
} else { check(false, "confirmed ownership has a journal record") }
journalRuntime.end(token: journalToken, now: 1)
journalRuntime.tick(token: journalToken, now: 4)
journalOutput.deliverPendingWrite()
journalRuntime.volumeChanged(token: journalToken, now: 4.1)
if case .absent = try runtimeJournal.read() {} else { check(false, "restored cycle removes journal") }
try FileManager.default.removeItem(at: journalDirectory)

let overrideDirectory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("voiceink-manual-volume-\(UUID().uuidString)")
let overrideJournal = try AudioDuckingRecoveryJournal(directory: overrideDirectory)
let overrideOutput = makeOutput([0.6])
overrideOutput.requiresWriteNotification = true
let overrideRuntime = AudioDuckingRuntime(output: overrideOutput, journal: overrideJournal)
let overrideToken = overrideRuntime.begin(sessionID: UUID(), desired: runtimeConfig)!
overrideRuntime.activate(token: overrideToken, now: 0)
overrideRuntime.volumeChanged(token: overrideToken, now: 0.1)
overrideOutput.devices[1] = AudioDuckingOutputSnapshot(deviceID: 1, uid: "one", elements: [1], values: [0.4], muted: false)
overrideRuntime.tick(token: overrideToken, now: 0.2)
check(overrideOutput.devices[1]!.values == [0.4] && !overrideRuntime.isQuarantined,
      "manual volume change is preserved without a permanent unresolved-write quarantine")
if case .record(let entry) = try overrideJournal.read() {
    check(entry.baseline == [0.6] && entry.confirmed == [0.4], "manual recording level preserves original baseline durably")
} else { check(false, "manual level retains restoration responsibility") }
check(overrideRuntime.manualAdjustment?.percent == 67, "manual volume is converted to retained percentage")
overrideRuntime.updateRetainedPercent(50, token: overrideToken, now: 0.3)
overrideRuntime.volumeChanged(token: overrideToken, now: 0.4)
check(abs(overrideOutput.devices[1]!.values[0] - 0.3) < 0.0001 && overrideRuntime.lease.baseline == [0.6],
      "settings adjustment after manual volume still uses the original baseline")
overrideRuntime.end(token: overrideToken, now: 1)
overrideRuntime.tick(token: overrideToken, now: 4)
overrideRuntime.volumeChanged(token: overrideToken, now: 4.1)
check(overrideRuntime.status == .idle && overrideOutput.devices[1]!.values == [0.6],
      "manual volume followed by settings adjustment restores the pre-recording baseline")
try FileManager.default.removeItem(at: overrideDirectory)

let callbackDirectory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("voiceink-manual-callback-\(UUID().uuidString)")
let callbackJournal = try AudioDuckingRecoveryJournal(directory: callbackDirectory)
let callbackOutput = makeOutput([0.6])
callbackOutput.requiresWriteNotification = true
let callbackRuntime = AudioDuckingRuntime(output: callbackOutput, journal: callbackJournal)
let callbackToken = callbackRuntime.begin(sessionID: UUID(), desired: runtimeConfig)!
callbackRuntime.activate(token: callbackToken, now: 0)
callbackRuntime.volumeChanged(token: callbackToken, now: 0.1)
let callbackWrites = callbackOutput.writes.count
callbackOutput.devices[1] = AudioDuckingOutputSnapshot(deviceID: 1, uid: "one", elements: [1], values: [0.4], muted: false)
callbackRuntime.volumeChanged(token: callbackToken, now: 0.2, observed: callbackOutput.devices[1])
callbackRuntime.end(token: callbackToken, now: 0.3)
callbackRuntime.tick(token: callbackToken, now: 4)
callbackRuntime.volumeChanged(token: callbackToken, now: 4.1)
check(callbackOutput.writes.count == callbackWrites + 1 && callbackOutput.devices[1]!.values == [0.6] && callbackRuntime.status == .idle,
      "a manual recording level restores the original baseline after Stop")
if case .absent = try callbackJournal.read() {} else { check(false, "callback manual takeover clears the stale recovery obligation") }
try FileManager.default.removeItem(at: callbackDirectory)

let recoveryDirectory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("voiceink-recovery-\(UUID().uuidString)")
let recoveryJournal = try AudioDuckingRecoveryJournal(directory: recoveryDirectory)
let recoveryOutput = makeOutput([0.12])
recoveryOutput.deferWrites = true
recoveryOutput.devices[2] = AudioDuckingOutputSnapshot(deviceID: 2, uid: "new", elements: [1], values: [0.9], muted: false)
recoveryOutput.selected = 2
let recoveryRecord = AudioDuckingRecoveryRecord(version: 1, cycleID: UUID(), deviceUID: "one", control: .physicalMain,
    elements: [1], stereoChannels: [], channelLayout: Data(), balance: nil, muted: false,
    baseline: [0.6], confirmed: [0.12], phase: .confirmed, intended: nil)
try recoveryJournal.write(recoveryRecord)
let coordinator = AudioDuckingRecoveryCoordinator(journal: recoveryJournal, output: recoveryOutput, resolve: { $0 == "one" ? 1 : nil })
coordinator.prepare()
if case .incomplete = coordinator.state {} else { check(false, "a persisted matching value alone does not prove ownership") }
check(recoveryOutput.writes.isEmpty, "startup cannot restore from an unproven value match")
coordinator.prepare(continuousOwnership: true)
if case .needsListener = coordinator.state {} else { check(false, "continuously owned old device is ready for named recovery") }
coordinator.issue(now: 0)
if case .record(let entry) = try recoveryJournal.read() { check(entry.phase == .writeIntent, "named recovery writes intent first") }
else { check(false, "named recovery retains intent") }
recoveryOutput.deliverPendingWrite()
coordinator.notified(now: 0.1)
if case .idle = coordinator.state {} else { check(false, "confirmed named restoration completes") }
check(recoveryOutput.devices[1]!.values == [0.6] && recoveryOutput.devices[2]!.values == [0.9],
      "named recovery restores only the original device")
if case .absent = try recoveryJournal.read() {} else { check(false, "confirmed named restoration clears journal") }

try recoveryJournal.write(recoveryRecord)
recoveryOutput.devices[1] = AudioDuckingOutputSnapshot(deviceID: 1, uid: "one", elements: [1], values: [0.4], muted: false)
let writesBeforeOverride = recoveryOutput.writes.count
coordinator.prepare()
if case .idle = coordinator.state {} else { check(false, "user volume change relinquishes recovery") }
check(recoveryOutput.writes.count == writesBeforeOverride && recoveryOutput.devices[1]!.values == [0.4],
      "named recovery never overwrites a changed volume")

let uncertainRecord = recoveryRecord.replacing(phase: .writeIntent, intended: [0.6])
try recoveryJournal.write(uncertainRecord)
coordinator.prepare()
if case .incomplete = coordinator.state {} else { check(false, "crash with in-flight intent remains incomplete") }
coordinator.issue(now: 10)
check(recoveryOutput.writes.count == writesBeforeOverride, "uncertain intent never triggers a blind retry")
try recoveryJournal.clear()

try recoveryJournal.write(recoveryRecord)
recoveryOutput.devices[1] = AudioDuckingOutputSnapshot(deviceID: 1, uid: "one", elements: [1], values: [0.12], muted: false)
coordinator.prepare(continuousOwnership: true)
coordinator.issue(now: 20)
let pendingRecoveryWrites = recoveryOutput.writes.count
coordinator.invalidate()
recoveryOutput.deliverPendingWrite()
coordinator.notified(now: 21)
check(recoveryOutput.writes.count == pendingRecoveryWrites, "sleep or route invalidation never schedules another write")
if case .record(let entry) = try recoveryJournal.read() { check(entry.phase == .writeIntent, "in-flight recovery keeps intent after invalidation") }
else { check(false, "invalidated recovery keeps journal") }
let missingCoordinator = AudioDuckingRecoveryCoordinator(journal: recoveryJournal, output: recoveryOutput, resolve: { _ in nil })
missingCoordinator.prepare(now: 100)
if case .deferredMissing(let deadline) = missingCoordinator.state { check(deadline == 130, "missing device has bounded wait") }
else { check(false, "missing device is deferred") }
missingCoordinator.tick(now: 130)
if case .incomplete = missingCoordinator.state {} else { check(false, "TTL does not resolve uncertainty") }
check(recoveryOutput.writes.count == pendingRecoveryWrites, "missing device never triggers a write")
if case .record = try recoveryJournal.read() {} else { check(false, "expiry preserves the uncertain journal") }
try recoveryJournal.write(recoveryRecord)
missingCoordinator.prepare(now: 200)
if case .deferredMissing(let deadline) = missingCoordinator.state { check(deadline == 230, "confirmed record also waits a bounded time") }
else { check(false, "confirmed missing device is deferred") }
missingCoordinator.tick(now: 230)
if case .incomplete = missingCoordinator.state {} else { check(false, "confirmed missing device remains unresolved after expiry") }
check(recoveryOutput.writes.count == pendingRecoveryWrites, "expiry never issues a recovery write")
try FileManager.default.removeItem(at: recoveryDirectory)

let originalVirtual = AudioDuckingOutputSnapshot(deviceID: 1, uid: "one", elements: [0], values: [0.6], muted: false, control: .virtualMain, stereoChannels: [1, 2], balance: 0.5)
let changedBalance = AudioDuckingOutputSnapshot(deviceID: 1, uid: "one", elements: [0], values: [0.6], muted: false, control: .virtualMain, stereoChannels: [1, 2], balance: 0.7)
let changedPair = AudioDuckingOutputSnapshot(deviceID: 1, uid: "one", elements: [0], values: [0.6], muted: false, control: .virtualMain, stereoChannels: [2, 1], balance: 0.5)
let changedLayout = AudioDuckingOutputSnapshot(deviceID: 1, uid: "one", elements: [0], values: [0.6], muted: false, control: .virtualMain, stereoChannels: [1, 2], balance: 0.5, channelLayout: Data([1]))
check(!originalVirtual.hasSameControls(as: changedBalance) && !originalVirtual.hasSameControls(as: changedPair),
      "virtual balance and channel topology participate in ownership")
check(!originalVirtual.hasSameControls(as: changedLayout), "preferred channel layout participates in ownership")

let takeoverAtWrite = makeOutput([0.6])
takeoverAtWrite.requiresWriteNotification = true
let takeoverAtWriteRuntime = AudioDuckingRuntime(output: takeoverAtWrite)
let takeoverAtWriteToken = takeoverAtWriteRuntime.begin(sessionID: UUID(), desired: runtimeConfig)!
takeoverAtWrite.beforeAdapterCheck = {
    takeoverAtWrite.devices[1] = AudioDuckingOutputSnapshot(deviceID: 1, uid: "one", elements: [1], values: [0.4], muted: false)
}
takeoverAtWriteRuntime.activate(token: takeoverAtWriteToken, now: 0)
check(takeoverAtWrite.writes.isEmpty && takeoverAtWrite.devices[1]!.values == [0.4],
      "the adapter does not overwrite a newer value observed immediately before the setter")
check(!takeoverAtWriteRuntime.isQuarantined && takeoverAtWriteRuntime.failureReason == "preflight_changed",
      "a rejected preflight does not invent an in-flight hardware write")

let cleanupTakeover = makeOutput([0.6])
let cleanupTakeoverRuntime = AudioDuckingRuntime(output: cleanupTakeover)
let cleanupTakeoverToken = cleanupTakeoverRuntime.begin(sessionID: UUID(), desired: runtimeConfig)!
cleanupTakeoverRuntime.activate(token: cleanupTakeoverToken, now: 0)
cleanupTakeover.beforeOwnedCheck = {
    cleanupTakeover.devices[1] = AudioDuckingOutputSnapshot(deviceID: 1, uid: "one", elements: [1], values: [0.4], muted: false)
}
cleanupTakeoverRuntime.invalidate(token: cleanupTakeoverToken)
check(cleanupTakeover.devices[1]!.values == [0.4] && !cleanupTakeoverRuntime.isQuarantined,
      "rejected named cleanup preserves the newer value without inventing an in-flight write")

let switchedControl = makeOutput([0.6])
let switchedRuntime = AudioDuckingRuntime(output: switchedControl)
let switchedToken = switchedRuntime.begin(sessionID: UUID(), desired: runtimeConfig)!
switchedControl.devices[1] = AudioDuckingOutputSnapshot(deviceID: 1, uid: "one", elements: [1], values: [0.6], muted: false, control: .virtualMain)
switchedRuntime.activate(token: switchedToken, now: 0)
check(switchedControl.writes.isEmpty && switchedRuntime.status == .unavailable,
      "a changed control kind cannot inherit the captured hardware lease")

let rounded = makeOutput([0.6])
rounded.requiresWriteNotification = true
rounded.roundingULP = true
let roundedRuntime = AudioDuckingRuntime(output: rounded)
let roundedToken = roundedRuntime.begin(sessionID: UUID(), desired: runtimeConfig)!
roundedRuntime.activate(token: roundedToken, now: 0)
roundedRuntime.volumeChanged(token: roundedToken, now: 0.1)
check(roundedRuntime.status == .active && !roundedRuntime.isQuarantined,
      "one-ULP hardware rounding is accepted after notification")
roundedRuntime.end(token: roundedToken, now: 1)
roundedRuntime.tick(token: roundedToken, now: 4)
roundedRuntime.volumeChanged(token: roundedToken, now: 4.1)
check(roundedRuntime.status == .idle && abs(rounded.devices[1]!.values[0] - 0.6) <= Float(0.6).ulp * 4,
      "restoration completes within a few floating-point ULPs of baseline")

let smallRounding = makeOutput([0.6])
smallRounding.requiresWriteNotification = true
smallRounding.roundingDelta = 0.0000005
let smallRoundingRuntime = AudioDuckingRuntime(output: smallRounding)
let smallRoundingToken = smallRoundingRuntime.begin(sessionID: UUID(), desired: runtimeConfig)!
smallRoundingRuntime.activate(token: smallRoundingToken, now: 0)
smallRoundingRuntime.volumeChanged(token: smallRoundingToken, now: 0.1)
smallRoundingRuntime.end(token: smallRoundingToken, now: 1)
smallRoundingRuntime.tick(token: smallRoundingToken, now: 4)
smallRoundingRuntime.volumeChanged(token: smallRoundingToken, now: 4.1)
check(smallRoundingRuntime.status == .idle && abs(smallRounding.devices[1]!.values[0] - 0.6) <= 0.000001,
      "sub-millionth hardware rounding can duck and restore")

let unpredictedQuantization = makeOutput([0.6])
unpredictedQuantization.requiresWriteNotification = true
unpredictedQuantization.quantizationStep = 0.1
unpredictedQuantization.predictsQuantization = false
let unpredictedRuntime = AudioDuckingRuntime(output: unpredictedQuantization)
let unpredictedToken = unpredictedRuntime.begin(sessionID: UUID(), desired: runtimeConfig)!
unpredictedRuntime.activate(token: unpredictedToken, now: 0)
unpredictedRuntime.volumeChanged(token: unpredictedToken, now: 0.1)
check(unpredictedRuntime.isQuarantined && unpredictedRuntime.status == .incomplete,
      "unpredicted device quantization is reported instead of being mistaken for ownership")

let takeover = makeOutput([0.6])
takeover.deferWrites = true
let takeoverRuntime = AudioDuckingRuntime(output: takeover)
let takeoverToken = takeoverRuntime.begin(sessionID: UUID(), desired: runtimeConfig)!
takeover.onWrite = {
    takeover.devices[1] = AudioDuckingOutputSnapshot(deviceID: 1, uid: "one", elements: [1], values: [0.3], muted: false)
}
takeoverRuntime.activate(token: takeoverToken, now: 0)
check(takeoverRuntime.status == .incomplete && takeover.writes.count == 1,
      "intervening user change is not claimed or restored")
check(takeoverRuntime.begin(sessionID: UUID(), desired: runtimeConfig) == nil,
      "uncertain user takeover blocks recapture")

let quantized = makeOutput([0.6])
quantized.quantizationStep = 0.1
var slowConfig = runtimeConfig
slowConfig.fadeDownSeconds = 1.5
let quantizedRuntime = AudioDuckingRuntime(output: quantized)
let quantizedToken = quantizedRuntime.begin(sessionID: UUID(), desired: slowConfig)!
quantizedRuntime.activate(token: quantizedToken, now: 0)
quantizedRuntime.tick(token: quantizedToken, now: 0.02)
check(quantizedRuntime.status == .active && quantized.writes.isEmpty,
      "known quantized no-op is skipped without scheduling an ambiguous write")
quantizedRuntime.tick(token: quantizedToken, now: 0.4)
check(quantizedRuntime.status == .active && quantized.writes.count == 1,
      "fade progresses once the device's next representable level is reached")
quantizedRuntime.end(token: quantizedToken, now: 2)
quantizedRuntime.tick(token: quantizedToken, now: 4)
check(quantizedRuntime.status == .idle && abs(quantized.devices[1]!.values[0] - 0.6) < 0.0001,
      "quantized output restores its original level")

// Duplicate HAL notifications do not imply a mute/topology change.
let eventBaseline = AudioDuckingOutputSnapshot(deviceID: 1, uid: "one", elements: [1, 2], values: [0.6, 0.3], muted: false)
let volumeOnlyEvent = AudioDuckingOutputSnapshot(deviceID: 1, uid: "one", elements: [1, 2], values: [0.2, 0.1], muted: false)
check(!volumeOnlyEvent.requiresInvalidation(comparedWith: eventBaseline), "duplicate mute notification during a volume change preserves the recording")
let muteEvent = AudioDuckingOutputSnapshot(deviceID: 1, uid: "one", elements: [1, 2], values: [0.2, 0.1], muted: true)
check(muteEvent.requiresInvalidation(comparedWith: eventBaseline), "an actual mute change requires explicit state reconciliation")
let deviceEvent = AudioDuckingOutputSnapshot(deviceID: 2, uid: "two", elements: [1, 2], values: [0.2, 0.1], muted: false)
check(deviceEvent.requiresInvalidation(comparedWith: eventBaseline), "an actual device change still invalidates")

// A system key adjustment immediately followed by Stop must not lose baseline.
let lastMomentOutput = makeOutput([0.6, 0.3])
let lastMomentRuntime = AudioDuckingRuntime(output: lastMomentOutput)
let lastMomentToken = lastMomentRuntime.begin(sessionID: UUID(), desired: runtimeConfig)!
lastMomentRuntime.activate(token: lastMomentToken, now: 0)
lastMomentOutput.devices[1] = AudioDuckingOutputSnapshot(deviceID: 1, uid: "one", elements: [1, 2], values: [0.24, 0.12], muted: false)
lastMomentRuntime.end(token: lastMomentToken, now: 1)
check(lastMomentRuntime.lease.baseline == [0.6, 0.3] && lastMomentRuntime.manualAdjustment?.percent == 40,
      "Stop captures a queued manual adjustment without changing the original baseline")
lastMomentRuntime.tick(token: lastMomentToken, now: 4)
check(lastMomentRuntime.status == .idle && lastMomentOutput.devices[1]!.values == [0.6, 0.3],
      "manual adjustment immediately before Stop restores both original channel levels")


// A confirmed recording tolerates an explicit user mute change without
// changing mute hardware or forgetting the original volume.
let muteDirectory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("voiceink-mute-state-\(UUID().uuidString)")
let muteJournal = try AudioDuckingRecoveryJournal(directory: muteDirectory)
let muteOutput = makeOutput([0.6, 0.3])
muteOutput.requiresWriteNotification = true
let muteRuntime = AudioDuckingRuntime(output: muteOutput, journal: muteJournal)
let muteToken = muteRuntime.begin(sessionID: UUID(), desired: runtimeConfig)!
muteRuntime.activate(token: muteToken, now: 0)
muteRuntime.volumeChanged(token: muteToken, now: 0.1)
muteRuntime.volumeChanged(token: muteToken, now: 0.2)
let beforeMuteWrites = muteOutput.writes.count
muteOutput.devices[1] = AudioDuckingOutputSnapshot(deviceID: 1, uid: "one", elements: [1, 2], values: [0.24, 0.12], muted: true)
check(muteRuntime.observeMuteChange(token: muteToken), "a user mute change with no pending write retains volume ownership")
check(muteRuntime.lease.baseline == [0.6, 0.3] && muteOutput.writes.count == beforeMuteWrites,
      "observing mute neither writes HAL nor replaces the original recording volume")
muteOutput.devices[1] = AudioDuckingOutputSnapshot(deviceID: 1, uid: "one", elements: [1, 2], values: [0.24, 0.12], muted: false)
check(muteRuntime.observeMuteChange(token: muteToken), "a later user unmute retains the same baseline")
muteRuntime.end(token: muteToken, now: 1)
muteRuntime.tick(token: muteToken, now: 4)
muteRuntime.volumeChanged(token: muteToken, now: 4.1)
muteRuntime.volumeChanged(token: muteToken, now: 4.2)
check(muteRuntime.status == .idle && AudioDuckingOutputSnapshot.levelsMatch(muteOutput.devices[1]!.values, [0.6, 0.3]),
      "mute and unmute during recording still restore the original stereo volume")
try FileManager.default.removeItem(at: muteDirectory)

let mutePendingOutput = makeOutput([0.6])
mutePendingOutput.requiresWriteNotification = true
mutePendingOutput.deferWrites = true
let mutePendingRuntime = AudioDuckingRuntime(output: mutePendingOutput)
let mutePendingToken = mutePendingRuntime.begin(sessionID: UUID(), desired: runtimeConfig)!
mutePendingRuntime.activate(token: mutePendingToken, now: 0)
check(mutePendingRuntime.observeMuteChange(token: mutePendingToken), "a duplicate unchanged mute notification does not confirm or discard a pending write")
check(mutePendingRuntime.hasPendingWrite, "an unchanged mute notification is not a volume acknowledgement")
mutePendingOutput.devices[1] = AudioDuckingOutputSnapshot(deviceID: 1, uid: "one", elements: [1], values: [0.6], muted: true)
check(!mutePendingRuntime.observeMuteChange(token: mutePendingToken), "a real mute change cannot resume an unconfirmed write")
mutePendingRuntime.invalidate(token: mutePendingToken)
check(mutePendingRuntime.isQuarantined, "a mute change with an in-flight write retains quarantine")

let muteLatch = AudioDuckingEventLatch()
check(muteLatch.admit(mutePendingToken, observedEpoch: muteLatch.currentEpoch()), "mute latch admits the recording")
let muteEpoch = muteLatch.pause(ifCurrent: mutePendingToken)!
check(!muteLatch.permits(mutePendingToken), "mute observation pauses all future normal writes")
check(muteLatch.resume(mutePendingToken, after: muteEpoch), "only the original unchanged epoch may resume")
let interruptedMuteEpoch = muteLatch.pause(ifCurrent: mutePendingToken)!
_ = muteLatch.invalidate()
check(!muteLatch.resume(mutePendingToken, after: interruptedMuteEpoch), "route or sleep during mute observation cannot be reopened")
check(muteLatch.pause(ifCurrent: mutePendingToken) == nil, "a later mute event cannot reopen an invalidated route")

var displayedRecording = AudioDuckingRecordingVolume()
displayedRecording.capture(eventBaseline)
check(abs(displayedRecording.percent(forUID: "one")! - 60) < 0.0001, "recording display captures the original level")
check(displayedRecording.values == [0.6, 0.3] && volumeOnlyEvent.values != displayedRecording.values,
      "a live volume change or runtime invalidation does not mutate the display snapshot")
check(displayedRecording.percent(forUID: "two") == nil, "a different output never inherits another device's display baseline")
displayedRecording.capture(volumeOnlyEvent, inherited: [0.6, 0.3])
check(displayedRecording.values == [0.6, 0.3], "rapid recordings display the inherited original volume, not the reduced readback")
print("AudioDucking mute continuity and recording display checks passed")

let pausedOutput = makeOutput([0.6])
pausedOutput.requiresWriteNotification = true
pausedOutput.deferWrites = true
let pausedLatch = AudioDuckingEventLatch()
let pausedRuntime = AudioDuckingRuntime(output: pausedOutput, normalWriteAllowed: { pausedLatch.permits($0) })
let pausedToken = pausedRuntime.begin(sessionID: UUID(), desired: runtimeConfig)!
check(pausedLatch.admit(pausedToken, observedEpoch: pausedLatch.currentEpoch()), "admit the pending-write pause fixture")
pausedRuntime.activate(token: pausedToken, now: 0)
pausedOutput.deliverPendingWrite()
let deliveredVolumeObservation = pausedOutput.devices[1]!
let pausedEpoch = pausedLatch.pause(ifCurrent: pausedToken)!
check(pausedLatch.isMutePaused(pausedToken), "mute pause is distinguishable from route invalidation")
let pausedWriteCount = pausedOutput.writes.count
pausedRuntime.tick(token: pausedToken, now: 0.1)
check(pausedOutput.writes.count == pausedWriteCount && pausedRuntime.hasPendingWrite, "pause permits neither another write nor invented acknowledgement")
check(pausedRuntime.observeMuteChange(token: pausedToken), "unchanged mute can resume without acknowledging the pending volume write")
check(pausedLatch.resume(pausedToken, after: pausedEpoch), "resume exactly the mute observation")
pausedRuntime.volumeChanged(token: pausedToken, now: 0.2, observed: deliveredVolumeObservation)
check(!pausedRuntime.hasPendingWrite && !pausedRuntime.isQuarantined, "a real buffered volume notification still acknowledges the write after mute inspection")
check(!pausedLatch.isMutePaused(pausedToken), "resumption retires the mute-pause marker")
print("AudioDucking mute pause notification checks passed")

let coalescedMuteLatch = AudioDuckingEventLatch()
check(coalescedMuteLatch.admit(pausedToken, observedEpoch: coalescedMuteLatch.currentEpoch()), "admit repeated mute fixture")
let firstMuteEpoch = coalescedMuteLatch.pause(ifCurrent: pausedToken)!
let latestMuteEpoch = coalescedMuteLatch.pause(ifCurrent: pausedToken)!
check(!coalescedMuteLatch.resume(pausedToken, after: firstMuteEpoch), "a later mute notification retires the earlier observation proof")
check(coalescedMuteLatch.resume(pausedToken, after: latestMuteEpoch), "the latest mute observation can resume if no lifecycle event intervened")
print("AudioDucking repeated mute observation checks passed")

let stopMuteOutput = makeOutput([0.6])
let stopMuteRuntime = AudioDuckingRuntime(output: stopMuteOutput)
let stopMuteToken = stopMuteRuntime.begin(sessionID: UUID(), desired: runtimeConfig)!
stopMuteRuntime.activate(token: stopMuteToken, now: 0)
stopMuteOutput.devices[1] = AudioDuckingOutputSnapshot(deviceID: 1, uid: "one", elements: [1], values: [0.24], muted: true)
stopMuteRuntime.end(token: stopMuteToken, now: 1)
check(stopMuteRuntime.lease.baseline == [0.6] && stopMuteRuntime.capturedOutput?.muted == true,
      "Stop reconciles a queued mute adjustment without recapturing the reduced volume")
stopMuteRuntime.tick(token: stopMuteToken, now: 4)
check(stopMuteRuntime.status == .idle && stopMuteOutput.devices[1]!.values == [0.6] && stopMuteOutput.devices[1]!.muted == true,
      "Stop restores the saved volume without overriding the user's mute choice")
print("AudioDucking queued mute at Stop checks passed")

let pausedStopOutput = makeOutput([0.6])
pausedStopOutput.requiresWriteNotification = true
pausedStopOutput.deferWrites = true
let pausedStopRuntime = AudioDuckingRuntime(output: pausedStopOutput)
let pausedStopToken = pausedStopRuntime.begin(sessionID: UUID(), desired: runtimeConfig)!
pausedStopRuntime.activate(token: pausedStopToken, now: 0)
pausedStopOutput.deliverPendingWrite()
let stoppedObservation = pausedStopOutput.devices[1]!
pausedStopRuntime.end(token: pausedStopToken, now: 0.1)
pausedStopRuntime.volumeChanged(token: pausedStopToken, now: 0.2, observed: stoppedObservation)
pausedStopRuntime.tick(token: pausedStopToken, now: 4)
pausedStopOutput.deliverPendingWrite()
pausedStopRuntime.volumeChanged(token: pausedStopToken, now: 4.1)
check(pausedStopRuntime.status == .idle && pausedStopOutput.devices[1]!.values == [0.6],
      "Stop before the buffered acknowledgement still restores the original volume")
print("AudioDucking Stop before buffered notification checks passed")

// Invalidation while the write intent is on disk must win final admission.
let admissionDirectory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("voiceink-admission-\(UUID().uuidString)")
defer { try? FileManager.default.removeItem(at: admissionDirectory) }
let admissionJournal = try AudioDuckingRecoveryJournal(directory: admissionDirectory)
let admissionOutput = makeOutput([0.6])
admissionOutput.requiresWriteNotification = true
let admissionLatch = AudioDuckingEventLatch()
var intentWasDurable = false
let admissionRuntime = AudioDuckingRuntime(output: admissionOutput, journal: admissionJournal,
    normalWriteAllowed: { admissionLatch.permits($0) }, writeAdmission: { token, operation in
        if case .record(let stored) = try? admissionJournal.read() { intentWasDurable = stored.phase == .writeIntent }
        _ = admissionLatch.invalidate()
        return admissionLatch.performWrite(ifCurrent: token, operation)
    })
let admissionToken = admissionRuntime.begin(sessionID: UUID(), desired: runtimeConfig)!
check(admissionLatch.admit(admissionToken, observedEpoch: admissionLatch.currentEpoch()), "admission test installs lease")
admissionRuntime.activate(token: admissionToken, now: 0)
check(intentWasDurable && admissionOutput.writes.isEmpty, "event after durable intent prevents the not-yet-issued setter")
check(!admissionRuntime.hasPendingWrite && !admissionRuntime.isQuarantined, "refused final admission is not an attempted setter")

// Events serialize with the synchronous setter, not its later hardware effect.
let orderedLatch = AudioDuckingEventLatch()
var orderedLease = AudioDuckingLease()
let orderedToken = orderedLease.begin(UUID())
check(orderedLatch.admit(orderedToken, observedEpoch: orderedLatch.currentEpoch()), "ordered setter admits token")
let eventEntered = DispatchSemaphore(value: 0)
let eventFinished = DispatchSemaphore(value: 0)
var orderedCalls = 0
_ = orderedLatch.performWrite(ifCurrent: orderedToken) {
    DispatchQueue.global().async {
        eventEntered.signal()
        _ = orderedLatch.invalidate()
        eventFinished.signal()
    }
    check(eventEntered.wait(timeout: .now() + 2) == .success, "concurrent invalidation reaches gate")
    check(eventFinished.wait(timeout: .now()) == .timedOut, "event cannot pass final admission during setter")
    orderedCalls += 1
    return .attempted(true)
}
check(eventFinished.wait(timeout: .now() + 2) == .success, "event completes after synchronous setter")
_ = orderedLatch.performWrite(ifCurrent: orderedToken) { orderedCalls += 1; return .attempted(true) }
check(orderedCalls == 1 && !orderedLatch.permits(orderedToken), "invalidated token cannot issue another setter")

// Runtime replacement for a different device cannot forget a late-write risk.
var liveEffects = AudioDuckingUnsettledWrites()
check(noNotificationRuntime.quarantinedDeviceUID == "one", "timed-out runtime retains the original UID")
liveEffects.retain(noNotificationRuntime.quarantinedDeviceUID)
let replacementRuntime = AudioDuckingRuntime(output: makeOutput([0.8]))
check(liveEffects.allows("two") && !liveEffects.allows("one"), "unsettled output blocks only its own UID after handoff")
noNotification.deliverPendingWrite()
check(!liveEffects.allows("one"), "late effect/readback cannot implicitly release process quarantine")
check(replacementRuntime.status == .idle, "replacement runtime does not erase the separate registry")
print("Final setter admission and retained live-effect quarantine checks passed")

// Named recovery uses the same final admission, after persisting its intent.
let gatedRecoveryJournal = try AudioDuckingRecoveryJournal(directory: admissionDirectory.appendingPathComponent("recovery"))
try gatedRecoveryJournal.write(recoveryRecord)
let gatedRecoveryOutput = makeOutput([0.12])
let gatedRecovery = AudioDuckingRecoveryCoordinator(journal: gatedRecoveryJournal, output: gatedRecoveryOutput, resolve: { _ in 1 })
gatedRecovery.prepare(continuousOwnership: true)
let recoveryGate = AudioDuckingEventLatch()
var recoveryGateLease = AudioDuckingLease()
let recoveryGateToken = recoveryGateLease.begin(UUID())
check(recoveryGate.admit(recoveryGateToken, observedEpoch: recoveryGate.currentEpoch()), "recovery gate admits token")
gatedRecovery.issue(now: 0, writeAdmission: { operation in
    _ = recoveryGate.invalidate()
    return recoveryGate.performWrite(ifCurrent: recoveryGateToken, operation)
})
check(gatedRecoveryOutput.writes.isEmpty && gatedRecovery.unsettledDeviceUID == nil,
      "recovery event after intent denies setter without inventing a pending effect")
check(coordinator.unsettledDeviceUID == "one", "invalidated recovery retains unsettled UID after late notification")
coordinator.prepare(continuousOwnership: true)
coordinator.issue(now: 50)
check(recoveryOutput.writes.count == pendingRecoveryWrites, "unsettled named recovery cannot be reissued by prepare")
print("Named recovery final admission and no-reissue checks passed")

// A quarantine/mode change must not strand a previous legacy mute when a new
// recording cancels the old delayed waiter. The production controller uses this
// ledger independently of the selected mode and keeps failed restores owned.
var inheritedMute = RecordingMuteOwnership()
let muteSessionA = UUID()
let muteSessionB = UUID()
inheritedMute.begin(muteSessionA)
inheritedMute.recordMuted(7)
check(inheritedMute.restorationDevices(for: muteSessionA, cancelled: false) == [7], "owned mute has restoration responsibility")
inheritedMute.begin(muteSessionB)
check(inheritedMute.restorationDevices(for: muteSessionA, cancelled: false).isEmpty,
      "cancelled/superseded waiter cannot restore over the new recording")
check(inheritedMute.hasDevices && inheritedMute.restorationDevices(for: muteSessionB, cancelled: true).isEmpty,
      "cancellation retains responsibility rather than dropping the owned mute")
check(inheritedMute.restorationDevices(for: muteSessionB, cancelled: false) == [7],
      "new recording restores inherited mute even when quarantine selects unchanged mode")
// A failed hardware restore deliberately does not call didRestore.
check(inheritedMute.restorationDevices(for: muteSessionB, cancelled: false) == [7], "failed unmute remains retryable by its owner")
inheritedMute.didRestore(7)
check(!inheritedMute.hasDevices, "confirmed unmute releases only its recorded device")
check(inheritedMute.restorationDevices(for: muteSessionB, cancelled: false).isEmpty,
      "a device muted before ownership was acquired is never unmuted")
print("Legacy mute cancellation and mode-independent restoration checks passed")

// Replay the service admission ordering with its production journal gate.
let handoffDirectory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("voiceink-handoff-\(UUID().uuidString)")
defer { try? FileManager.default.removeItem(at: handoffDirectory) }
let handoffJournal = try AudioDuckingRecoveryJournal(directory: handoffDirectory)
let handoffOutput = makeOutput([0.6])
handoffOutput.requiresWriteNotification = true
handoffOutput.deferWrites = true
let handoffLatch = AudioDuckingEventLatch()
let handoffRuntime = AudioDuckingRuntime(output: handoffOutput, journal: handoffJournal,
    normalWriteAllowed: { handoffLatch.permits($0) },
    writeAdmission: { handoffLatch.performWrite(ifCurrent: $0, $1) })
let handoffA = handoffRuntime.begin(sessionID: UUID(), desired: runtimeConfig)!
check(handoffLatch.admit(handoffA, observedEpoch: handoffLatch.currentEpoch()), "handoff admits original token")
handoffRuntime.activate(token: handoffA, now: 0)
handoffOutput.deliverPendingWrite()
handoffRuntime.volumeChanged(token: handoffA, now: 0.1)
guard case .record(let originalHandoff) = try handoffJournal.read() else { fatalError("confirmed handoff evidence missing") }
check(handoffRuntime.hasOwnershipCycle && originalHandoff.phase == .confirmed, "old recording owns a confirmed reduced level")
let beginEntryEpoch = handoffLatch.currentEpoch()
_ = handoffLatch.invalidate()
check(handoffLatch.pendingInvalidation() == handoffA, "route event is observed before queued cleanup")
handoffRuntime.invalidate(token: handoffA)
handoffLatch.clear(handoffA)
let deniedSameOutput = try handoffJournal.prepareRecordingCycle(inheriting: nil, selectedUID: "one")
check(!deniedSameOutput, "post-invalidation admission cannot recapture a reduced level as its baseline")
guard case .record(let untouchedHandoff) = try handoffJournal.read() else { fatalError("old recovery evidence erased") }
check(untouchedHandoff == originalHandoff, "same-output denial retains original baseline and confirmed values")
let foreignCycle = AudioDuckingRecoveryRecord(version: 1, cycleID: UUID(), deviceUID: "two", control: .physicalMain,
    elements: [1], stereoChannels: [], channelLayout: Data(), balance: nil, muted: false,
    baseline: [0.8], confirmed: [0.8], phase: .writeIntent, intended: [0.16])
var foreignRejected = false
do { try handoffJournal.writeOwned(foreignCycle) } catch { foreignRejected = true }
check(foreignRejected, "a setter cannot overwrite another cycle's active recovery record")
let allowedOtherOutput = try handoffJournal.prepareRecordingCycle(inheriting: nil, selectedUID: "two")
check(allowedOtherOutput, "a different output proceeds only after the original is durably held")
let heldOriginal = try handoffJournal.pendingRecovery(for: "one")?.1
let originalOutputBlocked = try handoffJournal.isAcknowledgedDeviceBlocked("one")
check(heldOriginal == originalHandoff && originalOutputBlocked, "original output remains blocked with its baseline preserved")
handoffOutput.devices[2] = AudioDuckingOutputSnapshot(deviceID: 2, uid: "two", elements: [1], values: [0.8], muted: false)
handoffOutput.selected = 2
let handoffB = handoffRuntime.begin(sessionID: UUID(), desired: runtimeConfig)!
check(!handoffLatch.admit(handoffB, observedEpoch: beginEntryEpoch), "an event during begin cannot be hidden by a later epoch sample")
check(handoffLatch.admit(handoffB, observedEpoch: handoffLatch.currentEpoch()), "a subsequent stable begin can admit the new output")
handoffRuntime.activate(token: handoffB, now: 1)
handoffRuntime.invalidate(token: handoffA)
check(handoffRuntime.lease.token == handoffB, "queued old-token cleanup cannot invalidate the replacement token")
guard case .record(let activeHandoff) = try handoffJournal.read() else { fatalError("replacement intent missing") }
let stillHeldOriginal = try handoffJournal.pendingRecovery(for: "one")?.1
check(activeHandoff.cycleID == handoffB.cycleID && stillHeldOriginal == originalHandoff,
      "replacement intent coexists with the previous output's complete held evidence")
print("Post-invalidation service admission and foreign-cycle preservation checks passed")

func driveAsyncTransition(_ runtime: AudioDuckingRuntime, _ output: FakeOutput,
                          token: AudioDuckingLease.Token, untilIdle: Bool, clock: inout Double) {
    for _ in 0..<500 {
        if untilIdle ? runtime.status == .idle : runtime.transitionSettled { return }
        clock += 0.01
        if runtime.hasPendingWrite {
            check(output.pendingWrite != nil, "fake hardware has exactly the issued pending effect")
            output.deliverPendingWrite()
            runtime.volumeChanged(token: token, now: clock)
        } else { runtime.tick(token: token, now: clock) }
    }
    check(false, "nonzero-duration asynchronous transition finishes within the fake clock bound")
}
func checkStereoFrames(_ output: FakeOutput) {
    check(output.writes.count > 4 && output.writes.count % 2 == 0, "fade contains multiple complete stereo samples")
    for index in stride(from: 0, to: output.writes.count, by: 2) {
        let left = output.writes[index], right = output.writes[index + 1]
        check(left.1 == 1 && right.1 == 2, "each sampled pair services both channels before the next pair")
        check(abs(left.2 / 0.6 - right.2 / 0.3) < 0.00001, "both targets in a sample retain the same balance coefficient")
    }
}
var timedConfig = runtimeConfig
timedConfig.fadeDownSeconds = 1.5
timedConfig.fadeUpSeconds = 1.5
timedConfig.restoreDelaySeconds = 0
let timedStereo = makeOutput([0.6, 0.3])
timedStereo.requiresWriteNotification = true
timedStereo.deferWrites = true
let timedRuntime = AudioDuckingRuntime(output: timedStereo)
let timedToken = timedRuntime.begin(sessionID: UUID(), desired: timedConfig)!
timedRuntime.activate(token: timedToken, now: 0)
timedRuntime.tick(token: timedToken, now: 0.02)
timedRuntime.updateRetainedPercent(50, token: timedToken, now: 0.021)
timedStereo.deliverPendingWrite()
timedRuntime.volumeChanged(token: timedToken, now: 0.03)
check(timedStereo.writes.count == 2 && timedStereo.writes[1].1 == 2, "later acknowledgment completes the sampled right channel before resampling left")
check(timedRuntime.effectiveConfiguration?.retainedPercent == 20, "live level change waits for the sampled channel pair")
timedStereo.deliverPendingWrite()
timedRuntime.volumeChanged(token: timedToken, now: 0.04)
check(timedRuntime.effectiveConfiguration?.retainedPercent == 50 && timedRuntime.lease.baseline == [0.6, 0.3],
      "live retarget starts after a balanced sample without changing the original baseline")
var timedClock = 0.04
driveAsyncTransition(timedRuntime, timedStereo, token: timedToken, untilIdle: false, clock: &timedClock)
check(AudioDuckingOutputSnapshot.levelsMatch(timedStereo.devices[1]!.values, [0.3, 0.15]), "nonzero stereo fade reaches retained target")
checkStereoFrames(timedStereo)
timedRuntime.end(token: timedToken, now: timedClock)
driveAsyncTransition(timedRuntime, timedStereo, token: timedToken, untilIdle: true, clock: &timedClock)
check(timedStereo.devices[1]!.values == [0.6, 0.3], "nonzero asynchronous restoration reaches the original stereo baseline")
checkStereoFrames(timedStereo)

let stoppedStereo = makeOutput([0.6, 0.3])
stoppedStereo.requiresWriteNotification = true
stoppedStereo.deferWrites = true
let stoppedRuntime = AudioDuckingRuntime(output: stoppedStereo)
let stoppedToken = stoppedRuntime.begin(sessionID: UUID(), desired: timedConfig)!
stoppedRuntime.activate(token: stoppedToken, now: 0)
stoppedRuntime.tick(token: stoppedToken, now: 0.02)
stoppedRuntime.end(token: stoppedToken, now: 0.021)
var stoppedClock = 0.021
driveAsyncTransition(stoppedRuntime, stoppedStereo, token: stoppedToken, untilIdle: true, clock: &stoppedClock)
check(stoppedStereo.devices[1]!.values == [0.6, 0.3], "Stop during a sampled pair still restores the original baseline")
checkStereoFrames(stoppedStereo)
print("Timed stereo frame fairness, live retarget and mid-pair Stop checks passed")

// A queued recovery block also fences a token that was admitted earlier.
let recoveryBlockedOutput = makeOutput([0.6])
recoveryBlockedOutput.requiresWriteNotification = true
recoveryBlockedOutput.deferWrites = true
var queuedRecoveryBlock = false
let blockedRuntime = AudioDuckingRuntime(output: recoveryBlockedOutput,
    normalWriteAllowed: { _ in !queuedRecoveryBlock },
    writeAdmission: { _, operation in queuedRecoveryBlock ? .notAttempted : operation() })
let blockedToken = blockedRuntime.begin(sessionID: UUID(), desired: runtimeConfig)!
blockedRuntime.activate(token: blockedToken, now: 0)
recoveryBlockedOutput.deliverPendingWrite()
blockedRuntime.volumeChanged(token: blockedToken, now: 0.1)
let writesBeforeRecoveryBlock = recoveryBlockedOutput.writes.count
blockedRuntime.end(token: blockedToken, now: 0.2)
queuedRecoveryBlock = true
blockedRuntime.tick(token: blockedToken, now: 10)
check(recoveryBlockedOutput.writes.count == writesBeforeRecoveryBlock,
      "recovery blocking after admission denies future restoration writes without revoking a newer token")
print("Queued recovery-block write fencing check passed")

// The production delayed-mute admission must honor the actual target UID,
// including durable held evidence after switching away and back.
do {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("voiceink-legacy-mute-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let journal = try AudioDuckingRecoveryJournal(directory: directory)
    let latch = AudioDuckingEventLatch()
    let settled = AudioDuckingUnsettledWrites()
    var calls = 0
    let setter = { calls += 1; return true }
    let one = { (deviceID: UInt32(1), uid: "one") }
    let two = { (deviceID: UInt32(2), uid: "two") }
    check(RecordingMuteAdmission.perform(deviceID: 1, journal: journal, unsettled: settled,
        latch: latch, readIdentity: one, operation: setter), "stable legacy mute can acquire a new effect")
    try journal.write(originalHandoff)
    check(!RecordingMuteAdmission.perform(deviceID: 1, journal: journal, unsettled: settled,
        latch: latch, readIdentity: one, operation: setter), "active recovery evidence denies a competing legacy mute")
    check(RecordingMuteAdmission.perform(deviceID: 2, journal: journal, unsettled: settled,
        latch: latch, readIdentity: two, operation: setter), "an unrelated output is not globally blocked by old evidence")
    try journal.holdMissingDevice(originalHandoff)
    check(!RecordingMuteAdmission.perform(deviceID: 1, journal: journal, unsettled: settled,
        latch: latch, readIdentity: one, operation: setter), "returning to a held UID during the mute delay does not bypass quarantine")
    let preservedMuteRecord = try journal.pendingRecovery(for: "one")
    check(preservedMuteRecord?.1 == originalHandoff,
          "denied mute preserves the held recovery record")
    var pending = AudioDuckingUnsettledWrites()
    pending.retain("two")
    check(!RecordingMuteAdmission.perform(deviceID: 2, journal: journal, unsettled: pending,
        latch: latch, readIdentity: two, operation: setter), "process-lifetime unsettled effects also block legacy mute")
    let beforeRaces = calls
    var reads = 0
    check(!RecordingMuteAdmission.perform(deviceID: 2, journal: journal, unsettled: settled,
        latch: latch, readIdentity: {
            reads += 1
            if reads == 1 { _ = latch.invalidate() }
            return two()
        }, operation: setter), "route or sleep invalidation during admission wins before the mute setter")
    reads = 0
    check(!RecordingMuteAdmission.perform(deviceID: 2, journal: journal, unsettled: settled,
        latch: latch, readIdentity: {
            reads += 1
            return (2, reads == 1 ? "two" : "replacement")
        }, operation: setter), "numeric ID reuse before final admission cannot target another UID")
    reads = 0
    check(!RecordingMuteAdmission.perform(deviceID: 2, journal: journal, unsettled: settled,
        latch: latch, readIdentity: {
            reads += 1
            return reads == 1 ? two() : one()
        }, operation: setter), "a new default output before the setter is rejected")
    check(!RecordingMuteAdmission.perform(deviceID: 2, journal: nil, unsettled: settled,
        latch: latch, readIdentity: two, operation: setter), "an unavailable recovery journal fails closed")
    check(!RecordingMuteAdmission.perform(deviceID: 2, journal: journal, unsettled: settled,
        latch: latch, readIdentity: { nil }, operation: setter), "a missing device identity fails closed")
    try Data("invalid".utf8).write(to: directory.appendingPathComponent("recovery-v1.json"))
    check(!RecordingMuteAdmission.perform(deviceID: 2, journal: journal, unsettled: settled,
        latch: latch, readIdentity: two, operation: setter), "unreadable active evidence cannot authorize legacy mute")
    check(calls == beforeRaces, "denied or invalidated admissions never invoke the HAL operation")
    var owned = RecordingMuteOwnership()
    let session = UUID()
    owned.begin(session); owned.recordMuted(9)
    check(owned.restorationDevices(for: session, cancelled: false) == [9],
          "new-effect quarantine does not revoke a previously owned unmute")
}
print("Delayed legacy mute UID, held recovery, unsettled effect and final admission checks passed")

// Rapid recording begins must drain an issued write, not turn it into a
// permanently orphaned intent. Exercise the production handoff and event latch.
for values: [Float] in [[0.6], [0.6, 0.3]] {
    for beginDuringRestore in [false, true] {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("voiceink-rapid-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AudioDuckingRecoveryJournal(directory: directory)
        let output = makeOutput(values)
        output.requiresWriteNotification = true
        output.deferWrites = true
        let latch = AudioDuckingEventLatch()
        let runtime = AudioDuckingRuntime(output: output, journal: journal, normalWriteAllowed: { latch.permits($0) })
        var cfg = runtimeConfig
        cfg.restoreDelaySeconds = 0.5
        let a = runtime.begin(sessionID: UUID(), desired: cfg)!
        check(latch.admit(a, observedEpoch: latch.currentEpoch()), "rapid fixture admitted")
        runtime.activate(token: a, now: 0)
        var clock = 0.0
        if beginDuringRestore {
            driveAsyncTransition(runtime, output, token: a, untilIdle: false, clock: &clock)
            runtime.end(token: a, now: 1)
            runtime.tick(token: a, now: 2)
            clock = 2
        }
        check(runtime.hasPendingWrite, "begin overlaps a real issued write")
        let issued = output.writes.count
        let b = runtime.begin(sessionID: UUID(), desired: cfg)!
        check(b != a && runtime.lease.token == a && runtime.lease.baseline == values,
              "new recording reserves its token without destroying pending confirmation or baseline")
        runtime.activate(token: b, now: clock + 0.22)
        runtime.tick(token: a, now: clock + 0.23)
        check(output.writes.count == issued && !runtime.isQuarantined, "old fade cannot advance while handing off")
        output.deliverPendingWrite()
        runtime.volumeChanged(token: a, now: clock + 0.25)
        if values.count == 2 {
            check(runtime.hasPendingWrite && output.writes.count == issued + 1,
                  "handoff finishes only the already sampled stereo pair")
            output.deliverPendingWrite()
            runtime.volumeChanged(token: a, now: clock + 0.255)
        }
        check(runtime.deferredBeginReady && output.writes.count == issued + values.count - 1,
              "acknowledgement stops before another old-session frame")
        let admitted = runtime.completeDeferredBegin(now: clock + 0.26) { old, new, _ in
            latch.handoff(from: old, to: new)
        }
        check(admitted == b && runtime.lease.baseline == values && b.cycleID == a.cycleID,
              "even the last restore confirmation retains the original ownership cycle")
        let beforeStale = output.writes.count
        runtime.end(token: a, now: clock + 0.27)
        runtime.volumeChanged(token: a, now: clock + 0.28)
        check(output.writes.count == beforeStale && !runtime.lease.ended, "stale old completion cannot stop the new recording")
        clock += 0.3
        driveAsyncTransition(runtime, output, token: b, untilIdle: false, clock: &clock)
        runtime.end(token: b, now: clock)
        driveAsyncTransition(runtime, output, token: b, untilIdle: true, clock: &clock)
        check(output.devices[1]!.values == values && !runtime.isQuarantined,
              "rapid mono/stereo recording returns to the exact original volume")
        if case .absent = try journal.read() {} else {
            check(false, "successful rapid cycle clears its recovery obligation")
        }
    }
}

for completion in ["short", "latest", "timeout", "route", "mutePause", "level"] {
    let output = makeOutput([0.6])
    output.requiresWriteNotification = true
    output.deferWrites = true
    let latch = AudioDuckingEventLatch()
    let runtime = AudioDuckingRuntime(output: output, normalWriteAllowed: { latch.permits($0) })
    let a = runtime.begin(sessionID: UUID(), desired: runtimeConfig)!
    check(latch.admit(a, observedEpoch: latch.currentEpoch()), "handoff edge fixture admitted")
    runtime.activate(token: a, now: 0)
    let b = runtime.begin(sessionID: UUID(), desired: runtimeConfig)!
    var latest = b
    if completion == "latest" {
        latest = runtime.begin(sessionID: UUID(), desired: runtimeConfig)!
        runtime.end(token: b, now: 0.2)
        runtime.activate(token: b, now: 0.22)
    }
    if completion == "short" {
        runtime.end(token: b, now: 0.1)
        runtime.end(token: b, now: 0.2)
        runtime.activate(token: b, now: 0.22)
    } else if completion != "level" { runtime.activate(token: latest, now: 0.22) }
    if completion == "timeout" {
        runtime.tick(token: a, now: 2.1)
        output.deliverPendingWrite()
        runtime.volumeChanged(token: a, now: 2.2)
        check(runtime.isQuarantined && runtime.deferredBeginToken == nil && output.writes.count == 1,
              "handoff retains the original bounded timeout and cannot revive a late unknown effect")
        continue
    }
    if completion == "route" {
        _ = latch.invalidate()
        runtime.invalidate(token: a)
        output.deliverPendingWrite()
        runtime.volumeChanged(token: a, now: 0.3)
        check(runtime.isQuarantined && runtime.deferredBeginToken == nil && output.writes.count == 1,
              "route/sleep invalidation discards deferred recording and quarantines the real pending effect")
        check(!latch.handoff(from: a, to: b), "handoff cannot reopen an invalidated event lease")
        continue
    }
    var pauseEpoch: UInt64?
    if completion == "mutePause" {
        pauseEpoch = latch.pause(ifCurrent: a)
        check(!latch.handoff(from: a, to: b), "temporary mute pause also denies handoff")
        check(runtime.observeMuteChange(token: a), "unchanged mute observation retains the pending confirmation")
        check(latch.resume(a, after: pauseEpoch!), "only the observed mute pause resumes")
    }
    if completion == "level" { runtime.updateRetainedPercent(55, token: b, now: 0.1) }
    output.deliverPendingWrite()
    runtime.volumeChanged(token: a, now: 0.3)
    check(runtime.completeDeferredBegin(now: 0.31, admit: { old, new, _ in latch.handoff(from: old, to: new) }) == latest,
          "latest deferred recording binds only after confirmation")
    if completion == "short" {
        check(runtime.lease.ended && runtime.lease.restoreDeadline == 2.1,
              "short deferred recording restores without late activation and keeps the first Stop deadline")
    } else if completion == "level" {
        check(output.writes.count == 1 && runtime.effectiveConfiguration?.retainedPercent == 55,
              "deferred live percentage does not bypass the activation grace period")
        runtime.activate(token: b, now: 0.4)
    } else { check(!runtime.lease.ended, "stale deferred Stop cannot stop the latest recording") }
    var clock = 0.5
    if !runtime.lease.ended { runtime.end(token: latest, now: clock) }
    driveAsyncTransition(runtime, output, token: latest, untilIdle: true, clock: &clock)
    check(output.devices[1]!.values == [0.6] && !runtime.isQuarantined, "deferred lifecycle edge restores original baseline")
}
print("AudioDucking pending-write recording handoff checks passed")

// Stress many overlapping generations with nonzero fades. Superseded tokens
// remain fenced, while every eventual Stop still targets the first baseline.
for stereo in [false, true] {
    let baseline: [Float] = stereo ? [0.6, 0.3] : [0.6]
    let output = makeOutput(baseline)
    output.requiresWriteNotification = true
    output.deferWrites = true
    let latch = AudioDuckingEventLatch()
    let runtime = AudioDuckingRuntime(output: output, normalWriteAllowed: { latch.permits($0) })
    var cfg = runtimeConfig
    cfg.fadeDownSeconds = 0.5
    cfg.fadeUpSeconds = 0.5
    cfg.restoreDelaySeconds = 0
    var token = runtime.begin(sessionID: UUID(), desired: cfg)!
    check(latch.admit(token, observedEpoch: latch.currentEpoch()), "stress initial lease admitted")
    var clock = 0.0
    runtime.activate(token: token, now: clock)
    for iteration in 0..<200 {
        clock += 0.01
        runtime.tick(token: token, now: clock)
        if !runtime.hasPendingWrite { continue }
        let old = token
        let next = runtime.begin(sessionID: UUID(), desired: cfg)!
        runtime.activate(token: next, now: clock + 0.001)
        if iteration % 3 == 0 { runtime.end(token: next, now: clock + 0.002) }
        output.deliverPendingWrite()
        runtime.volumeChanged(token: old, now: clock + 0.003)
        if stereo {
            check(runtime.hasPendingWrite, "stereo handoff retains the right-channel confirmation")
            output.deliverPendingWrite()
            runtime.volumeChanged(token: old, now: clock + 0.0035)
        }
        if iteration % 5 == 0 {
            let epoch = latch.pause(ifCurrent: old)!
            check(runtime.completeDeferredBegin(now: clock + 0.004, admit: { a, b, _ in latch.handoff(from: a, to: b) }) == nil,
                  "pause before runtime admission preserves the deferred request")
            check(runtime.deferredBeginToken == next && !runtime.isQuarantined,
                  "temporary pause must not cancel a healthy pending handoff")
            check(runtime.observeMuteChange(token: old) && latch.resume(old, after: epoch), "paused handoff can resume after unchanged mute proof")
        }
        token = runtime.completeDeferredBegin(now: clock + 0.005, admit: { a, b, _ in latch.handoff(from: a, to: b) })!
        check(token == next && runtime.lease.baseline == baseline && !runtime.isQuarantined,
              "repeated handoffs preserve the first baseline without quarantine")
        let writes = output.writes.count
        runtime.volumeChanged(token: old, now: clock + 0.006)
        runtime.end(token: old, now: clock + 0.007)
        check(output.writes.count == writes, "superseded generation cannot advance writes")
    }
    runtime.end(token: token, now: clock)
    driveAsyncTransition(runtime, output, token: token, untilIdle: true, clock: &clock)
    check(output.devices[1]!.values == baseline && !runtime.isQuarantined,
          "rapid 200-generation mono/stereo sequence restores the original baseline")
    if stereo { checkStereoFrames(output) }
}
print("AudioDucking repeated generation and mute-pause handoff stress checks passed")

// A mute pause can occur inside the latch admission callback, after runtime's
// initial permit check. Failed admission must not retire the original lease.
for interruption in ["mute", "route", "listenerFailure"] {
    let output = makeOutput([0.6])
    output.requiresWriteNotification = true
    output.deferWrites = true
    let latch = AudioDuckingEventLatch()
    let runtime = AudioDuckingRuntime(output: output, normalWriteAllowed: { latch.permits($0) })
    let a = runtime.begin(sessionID: UUID(), desired: runtimeConfig)!
    check(latch.admit(a, observedEpoch: latch.currentEpoch()), "mid-admission fixture admitted")
    runtime.activate(token: a, now: 0)
    let b = runtime.begin(sessionID: UUID(), desired: runtimeConfig)!
    runtime.activate(token: b, now: 0.22)
    output.deliverPendingWrite()
    runtime.volumeChanged(token: a, now: 0.3)
    var pause: UInt64?
    let attempted = runtime.completeDeferredBegin(now: 0.31) { old, next, _ in
        if interruption == "mute" { pause = latch.pause(ifCurrent: old) }
        else if interruption == "route" { _ = latch.invalidate() }
        else {
            check(latch.handoff(from: old, to: next), "listener failure occurs only after real latch transfer")
            _ = latch.invalidate(ifCurrent: next)
            latch.clear(next)
            return false
        }
        return latch.handoff(from: old, to: next)
    }
    check(attempted == nil && runtime.lease.token == a && runtime.deferredBeginToken == b && runtime.lease.baseline == [0.6],
          "admission failure never mutates the original lease, request or baseline")
    check(output.writes.count == 1, "mid-admission event cannot issue another setter")
    if interruption == "mute" {
        check(runtime.observeMuteChange(token: a) && latch.resume(a, after: pause!), "unchanged mute can reconcile the original lease")
        check(runtime.completeDeferredBegin(now: 0.32, admit: { old, next, _ in latch.handoff(from: old, to: next) }) == b,
              "the original deferred recording survives a mid-admission mute pause")
        runtime.end(token: b, now: 0.4)
        var clock = 0.4
        driveAsyncTransition(runtime, output, token: b, untilIdle: true, clock: &clock)
        check(output.devices[1]!.values == [0.6], "mid-admission mute pause still restores the original baseline")
    } else {
        // Production service retires the retained old lease when admission was
        // revoked rather than temporarily paused; it never retries the setter.
        runtime.invalidate(token: a)
        runtime.tick(token: b, now: 10)
        check(runtime.deferredBeginToken == nil && output.writes.count == 1,
              "route and failed listener installation cannot revive deferred writes")
    }
}

for path in ["queued-active", "superseded-deferred", "latest-level"] {
    let output = makeOutput([0.6])
    output.requiresWriteNotification = true
    output.deferWrites = true
    let runtime = AudioDuckingRuntime(output: output)
    let a = runtime.begin(sessionID: UUID(), desired: runtimeConfig)!
    runtime.activate(token: a, now: 0)
    if path == "queued-active" { runtime.updateRetainedPercent(55, token: a, now: 0.01) }
    var desired = runtimeConfig; desired.retainedPercent = 55
    var next = runtime.begin(sessionID: UUID(), desired: desired)!
    if path != "queued-active" {
        runtime.updateRetainedPercent(55, token: next, now: 0.02)
        if path == "latest-level" { runtime.updateRetainedPercent(60, token: next, now: 0.03) }
        next = runtime.begin(sessionID: UUID(), desired: desired)!
    }
    runtime.activate(token: next, now: 0.22)
    output.deliverPendingWrite()
    runtime.volumeChanged(token: a, now: 0.3)
    check(runtime.completeDeferredBegin(now: 0.31, admit: { _, _, _ in true }) == next, "bind latest percentage fixture")
    let expected: Double = path == "latest-level" ? 60 : 55
    check(runtime.effectiveConfiguration?.retainedPercent == expected && runtime.lease.baseline == [0.6],
          "latest queued active/deferred percentage survives recording replacement")
    var clock = 0.4
    driveAsyncTransition(runtime, output, token: next, untilIdle: false, clock: &clock)
    check(AudioDuckingOutputSnapshot.levelsMatch(output.devices[1]!.values, [0.6 * Float(expected / 100)]),
          "hardware target uses the retained percentage shown in settings")
    runtime.end(token: next, now: clock)
    driveAsyncTransition(runtime, output, token: next, untilIdle: true, clock: &clock)
    check(output.devices[1]!.values == [0.6], "carried percentage never changes the pre-recording baseline")
}
print("Mid-admission lifecycle race and queued percentage carry regression checks passed")

// One runtime-owned selected level spans active writes, Stop, mute pauses and
// every inherited recording. Service pause handling uses these exact APIs.
for values: [Float] in [[0.6], [0.6, 0.3]] {
    for phase in ["pending", "settled", "partial", "restored"] {
        if phase == "partial" && values.count == 1 { continue }
        for stopBeforeBegin in [false, true] {
            for replace in [false, true] {
                let output = makeOutput(values)
                output.requiresWriteNotification = true
                output.deferWrites = true
                let latch = AudioDuckingEventLatch()
                let runtime = AudioDuckingRuntime(output: output, normalWriteAllowed: { latch.permits($0) })
                var cfg = runtimeConfig; cfg.restoreDelaySeconds = 0
                let a = runtime.begin(sessionID: UUID(), desired: cfg)!
                check(latch.admit(a, observedEpoch: latch.currentEpoch()), "unified intent fixture admitted")
                runtime.activate(token: a, now: 0)
                var clock = 0.0
                var pause: UInt64?
                if phase == "settled" || phase == "restored" {
                    driveAsyncTransition(runtime, output, token: a, untilIdle: false, clock: &clock)
                }
                if phase == "restored" {
                    clock += 0.1
                    runtime.end(token: a, now: clock)
                    runtime.tick(token: a, now: clock)
                    if values.count == 2 {
                        output.deliverPendingWrite()
                        runtime.volumeChanged(token: a, now: clock + 0.01)
                    }
                }
                if phase == "partial" || phase == "restored" {
                    output.deliverPendingWrite()
                    output.onReadDefault = { output.onReadDefault = nil; pause = latch.pause(ifCurrent: a) }
                    runtime.volumeChanged(token: a, now: clock + 0.02)
                    check(!runtime.hasPendingWrite, "acknowledgement can finish before the pause blocks another setter")
                    if phase == "partial" { check(runtime.needsRecordingHandoff, "an unfinished stereo frame is still a handoff obligation") }
                } else { pause = latch.pause(ifCurrent: a) }
                check(pause != nil && runtime.lease.baseline == values && runtime.hasOwnershipCycle,
                      "every captured paused baseline retains its ownership cycle")
                let writes = output.writes.count
                runtime.updateRetainedPercent(55, token: a, now: clock + 0.03, deferEffects: true)
                if stopBeforeBegin { runtime.end(token: a, now: clock + 0.04) }
                var desired = cfg; desired.retainedPercent = 55
                var next = runtime.begin(sessionID: UUID(), desired: desired, deferUntilAdmitted: true)!
                if replace {
                    runtime.updateRetainedPercent(60, token: next, now: clock + 0.05)
                    next = runtime.begin(sessionID: UUID(), desired: desired, deferUntilAdmitted: true)!
                }
                runtime.activate(token: next, now: clock + 0.22)
                check(runtime.lease.token == a && output.writes.count == writes,
                      "mute-paused pending, settled, partial and restored states never advance early")
                check(runtime.observeMuteChange(token: a) && latch.resume(a, after: pause!), "reconcile only the observed mute pause")
                // Models the old Stop buffered in the service: it cannot erase
                // a newer recording's selected percentage or restoration duty.
                runtime.end(token: a, now: clock + 0.23)
                check(!runtime.resumeRetainedPercent(token: a, now: clock + 0.24), "the old token cannot consume the new recording's intent")
                for _ in 0..<3 {
                    clock += 0.1
                    if runtime.hasPendingWrite {
                        output.deliverPendingWrite()
                        runtime.volumeChanged(token: a, now: clock)
                    } else { runtime.tick(token: a, now: clock) }
                    if runtime.deferredBeginReady { break }
                }
                check(runtime.deferredBeginReady, "finish only the already sampled frame before transferring captured ownership")
                check(runtime.completeDeferredBegin(now: clock, admit: { old, new, _ in latch.handoff(from: old, to: new) }) == next,
                      "all paused ownership states admit the deferred recording after reconciliation")
                let expected: Double = replace ? 60 : 55
                check(runtime.effectiveConfiguration?.retainedPercent == expected && runtime.lease.baseline == values,
                      "latest selected percentage survives pause, Stop and repeated begin")
                driveAsyncTransition(runtime, output, token: next, untilIdle: false, clock: &clock)
                check(AudioDuckingOutputSnapshot.levelsMatch(output.devices[1]!.values, values.map { $0 * Float(expected / 100) }),
                      "resumed hardware level matches the selected percentage")
                runtime.end(token: next, now: clock)
                driveAsyncTransition(runtime, output, token: next, untilIdle: true, clock: &clock)
                check(output.devices[1]!.values == values && !runtime.hasOwnershipCycle && !runtime.isQuarantined,
                      "every paused-state path restores baseline and releases ownership")
            }
        }
    }
}

for updateAfterStop in [false, true] {
    let output = makeOutput([0.6]); output.requiresWriteNotification = true; output.deferWrites = true
    let runtime = AudioDuckingRuntime(output: output)
    let a = runtime.begin(sessionID: UUID(), desired: runtimeConfig)!
    runtime.activate(token: a, now: 0)
    if !updateAfterStop { runtime.updateRetainedPercent(55, token: a, now: 0.01) }
    runtime.end(token: a, now: 0.02)
    if updateAfterStop { runtime.updateRetainedPercent(55, token: a, now: 0.03) }
    var desired = runtimeConfig; desired.retainedPercent = 55
    let b = runtime.begin(sessionID: UUID(), desired: desired)!
    runtime.activate(token: b, now: 0.22)
    output.deliverPendingWrite(); runtime.volumeChanged(token: a, now: 0.3)
    check(runtime.completeDeferredBegin(now: 0.31, admit: { _, _, _ in true }) == b, "Stop fixture binds replacement")
    check(runtime.effectiveConfiguration?.retainedPercent == 55, "Stop cancels the old effect, not the selected level")
    var clock = 0.4
    driveAsyncTransition(runtime, output, token: b, untilIdle: false, clock: &clock)
    check(AudioDuckingOutputSnapshot.levelsMatch(output.devices[1]!.values, [0.33]), "Stop handoff targets selected 55 percent")
    runtime.end(token: b, now: clock)
    driveAsyncTransition(runtime, output, token: b, untilIdle: true, clock: &clock)
    check(output.devices[1]!.values == [0.6], "Stop handoff preserves original baseline")
}

// A real mute-only change must not publish the old level over a queued choice.
let selectedMuteOutput = makeOutput([0.6]); selectedMuteOutput.requiresWriteNotification = true; selectedMuteOutput.deferWrites = true
let selectedMuteLatch = AudioDuckingEventLatch()
let selectedMuteRuntime = AudioDuckingRuntime(output: selectedMuteOutput, normalWriteAllowed: { selectedMuteLatch.permits($0) })
let selectedMuteToken = selectedMuteRuntime.begin(sessionID: UUID(), desired: runtimeConfig)!
check(selectedMuteLatch.admit(selectedMuteToken, observedEpoch: selectedMuteLatch.currentEpoch()), "selected mute fixture admitted")
selectedMuteRuntime.activate(token: selectedMuteToken, now: 0)
var selectedMuteClock = 0.0
driveAsyncTransition(selectedMuteRuntime, selectedMuteOutput, token: selectedMuteToken, untilIdle: false, clock: &selectedMuteClock)
let selectedMuteEpoch = selectedMuteLatch.pause(ifCurrent: selectedMuteToken)!
selectedMuteRuntime.updateRetainedPercent(55, token: selectedMuteToken, now: 0.1, deferEffects: true)
let sameLevel = selectedMuteOutput.devices[1]!
selectedMuteOutput.devices[1] = AudioDuckingOutputSnapshot(deviceID: sameLevel.deviceID, uid: sameLevel.uid, elements: sameLevel.elements, values: sameLevel.values, muted: true)
check(selectedMuteRuntime.observeMuteChange(token: selectedMuteToken) && selectedMuteRuntime.manualAdjustment == nil,
      "mute-only metadata is not a new manual volume selection")
check(selectedMuteLatch.resume(selectedMuteToken, after: selectedMuteEpoch), "resume actual mute metadata")
check(selectedMuteRuntime.resumeRetainedPercent(token: selectedMuteToken, now: 0.2), "resume the sole runtime-owned queued choice")
selectedMuteClock = 0.2
driveAsyncTransition(selectedMuteRuntime, selectedMuteOutput, token: selectedMuteToken, untilIdle: false, clock: &selectedMuteClock)
check(selectedMuteRuntime.effectiveConfiguration?.retainedPercent == 55, "mute reconciliation preserves selected percentage")
selectedMuteRuntime.end(token: selectedMuteToken, now: selectedMuteClock)
driveAsyncTransition(selectedMuteRuntime, selectedMuteOutput, token: selectedMuteToken, untilIdle: true, clock: &selectedMuteClock)
check(selectedMuteOutput.devices[1]!.values == [0.6] && selectedMuteOutput.devices[1]!.muted == true,
      "restoration keeps original volume without writing the owner's mute state")
print("Unified selected-level, Stop and captured mute-pause state matrix passed")

for retained in [20.0, 100.0] {
    for baseline: [Float] in [[0.6], [0.6, 0.3]] {
        let output = makeOutput(baseline); output.requiresWriteNotification = true; output.deferWrites = true
        let latch = AudioDuckingEventLatch()
        let runtime = AudioDuckingRuntime(output: output, normalWriteAllowed: { latch.permits($0) })
        var cfg = runtimeConfig; cfg.retainedPercent = retained; cfg.restoreDelaySeconds = 0
        let a = runtime.begin(sessionID: UUID(), desired: cfg)!
        check(latch.admit(a, observedEpoch: latch.currentEpoch()), "captured-cycle fixture admitted")
        runtime.activate(token: a, now: 0)
        var clock = 0.0
        driveAsyncTransition(runtime, output, token: a, untilIdle: false, clock: &clock)
        let count = output.writes.count
        var changed = cfg; changed.mode = .unchanged; changed.fadeUpSeconds = 9
        let b = runtime.begin(sessionID: UUID(), desired: changed, deferUntilAdmitted: true)!
        check(runtime.completeDeferredBegin(now: clock, admit: { old, new, _ in latch.handoff(from: old, to: new) }) == b,
              "settled and untouched captured cycles use atomic admission too")
        check(output.writes.count == count && runtime.lease.baseline == baseline,
              "normal captured-cycle handoff never bypasses activation grace")
        check(runtime.effectiveConfiguration == cfg, "mode and timing remain fixed for captured ownership cycle")
        runtime.activate(token: b, now: clock + 0.22)
        clock += 0.22
        driveAsyncTransition(runtime, output, token: b, untilIdle: false, clock: &clock)
        runtime.end(token: b, now: clock)
        driveAsyncTransition(runtime, output, token: b, untilIdle: true, clock: &clock)
        check(output.devices[1]!.values == baseline && !runtime.hasOwnershipCycle,
              "captured-cycle admission including 100 percent releases ownership without extra effects")
    }
}

let capturedJournalDirectory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("voiceink-captured-final-\(UUID().uuidString)")
let capturedJournal = try AudioDuckingRecoveryJournal(directory: capturedJournalDirectory)
let capturedOutput = makeOutput([0.6]); capturedOutput.requiresWriteNotification = true; capturedOutput.deferWrites = true
let capturedLatch = AudioDuckingEventLatch()
let capturedRuntime = AudioDuckingRuntime(output: capturedOutput, journal: capturedJournal, normalWriteAllowed: { capturedLatch.permits($0) })
var capturedConfig = runtimeConfig; capturedConfig.restoreDelaySeconds = 0
let capturedA = capturedRuntime.begin(sessionID: UUID(), desired: capturedConfig)!
check(capturedLatch.admit(capturedA, observedEpoch: capturedLatch.currentEpoch()), "final captured journal admitted")
capturedRuntime.activate(token: capturedA, now: 0)
capturedOutput.deliverPendingWrite(); capturedRuntime.volumeChanged(token: capturedA, now: 0.1)
capturedRuntime.end(token: capturedA, now: 0.2); capturedRuntime.tick(token: capturedA, now: 0.2)
capturedOutput.deliverPendingWrite()
var capturedPause: UInt64?
capturedOutput.onReadDefault = { capturedOutput.onReadDefault = nil; capturedPause = capturedLatch.pause(ifCurrent: capturedA) }
capturedRuntime.volumeChanged(token: capturedA, now: 0.3)
check(capturedRuntime.lease.baseline == [0.6] && !capturedRuntime.hasPendingWrite && capturedRuntime.hasOwnershipCycle,
      "confirmed baseline still has a cycle until restoration is finalized")
let admittedCapturedJournal = try capturedJournal.prepareRecordingCycle(inheriting: capturedA.cycleID, selectedUID: "one")
check(admittedCapturedJournal, "same captured cycle remains valid against its durable confirmed record")
let capturedB = capturedRuntime.begin(sessionID: UUID(), desired: capturedConfig, deferUntilAdmitted: true)!
check(capturedRuntime.observeMuteChange(token: capturedA) && capturedLatch.resume(capturedA, after: capturedPause!), "resume final restoration observation")
check(capturedRuntime.completeDeferredBegin(now: 0.4, admit: { old, new, _ in capturedLatch.handoff(from: old, to: new) }) == capturedB,
      "last-frame confirmed baseline hands off without orphaning durable recovery")
capturedRuntime.end(token: capturedB, now: 0.5)
var capturedClock = 0.5
driveAsyncTransition(capturedRuntime, capturedOutput, token: capturedB, untilIdle: true, clock: &capturedClock)
if case .absent = try capturedJournal.read() {} else { check(false, "completed inherited cycle clears its own durable record") }
try FileManager.default.removeItem(at: capturedJournalDirectory)
print("Normal, 100-percent and final-confirmed captured-cycle checks passed")

// A mute-only observation must survive an interrupted process before any
// subsequent volume write. Restart inventory may not discard that baseline.
for baseline: [Float] in [[0.6], [0.6, 0.3]] {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("voiceink-mute-relaunch-\(UUID().uuidString)")
    let journal = try AudioDuckingRecoveryJournal(directory: directory)
    let output = makeOutput(baseline); output.requiresWriteNotification = true; output.deferWrites = true
    let latch = AudioDuckingEventLatch()
    let runtime = AudioDuckingRuntime(output: output, journal: journal, normalWriteAllowed: { latch.permits($0) })
    let token = runtime.begin(sessionID: UUID(), desired: runtimeConfig)!
    check(latch.admit(token, observedEpoch: latch.currentEpoch()), "durable mute fixture admitted")
    runtime.activate(token: token, now: 0)
    var clock = 0.0
    driveAsyncTransition(runtime, output, token: token, untilIdle: false, clock: &clock)
    let pausedEpoch = latch.pause(ifCurrent: token)!
    runtime.updateRetainedPercent(55, token: token, now: clock, deferEffects: true)
    let transition = runtime.lease.transition
    let originalConfig = runtime.effectiveConfiguration
    let current = output.devices[1]!
    output.devices[1] = AudioDuckingOutputSnapshot(deviceID: current.deviceID, uid: current.uid,
        elements: current.elements, values: current.values, muted: true, control: current.control,
        stereoChannels: current.stereoChannels, balance: current.balance, channelLayout: current.channelLayout)
    let writes = output.writes.count
    check(runtime.observeMuteChange(token: token), "mute-only metadata durably confirmed")
    check(output.writes.count == writes && runtime.manualAdjustment == nil && runtime.lease.baseline == baseline,
          "durable mute observation neither writes hardware nor adopts a new baseline")
    check(runtime.effectiveConfiguration == originalConfig && runtime.lease.transition?.end == transition?.end,
          "durable mute metadata preserves selected configuration and sampled transition")
    guard case .record(let stored) = try journal.read() else { check(false, "durable mute record exists"); exit(1) }
    check(stored.phase == .confirmed && stored.muted == true && stored.baseline == baseline && stored.confirmed == current.values,
          "journal retains original baseline and updated mute at the confirmed level")
    let restarted = AudioDuckingRecoveryCoordinator(journal: journal, output: output, resolve: { $0 == current.uid ? 1 : nil })
    restarted.prepare(now: 10)
    if case .incomplete = restarted.state {} else { check(false, "restart retains ambiguous confirmed ownership without restoring") }
    guard case .record(let afterRestart) = try journal.read() else { check(false, "restart must not erase the volume obligation"); exit(1) }
    check(afterRestart == stored && output.writes.count == writes, "restart inventory preserves journal and performs no setters")
    check(latch.resume(token, after: pausedEpoch), "confirmed durable mute metadata permits the original epoch to resume")
    check(runtime.resumeRetainedPercent(token: token, now: clock + 0.1), "mute persistence retains the pending selected level")
    check(runtime.effectiveConfiguration?.retainedPercent == 55, "mute persistence retains the exact selected percentage")
    try FileManager.default.removeItem(at: directory)
}

let failedMuteDirectory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("voiceink-mute-journal-failure-\(UUID().uuidString)")
let failedMuteJournal = try AudioDuckingRecoveryJournal(directory: failedMuteDirectory)
let failedMuteOutput = makeOutput([0.6])
let failedMuteRuntime = AudioDuckingRuntime(output: failedMuteOutput, journal: failedMuteJournal)
let failedMuteToken = failedMuteRuntime.begin(sessionID: UUID(), desired: runtimeConfig)!
failedMuteRuntime.activate(token: failedMuteToken, now: 0)
let failedMuteBefore = failedMuteOutput.devices[1]!
failedMuteOutput.devices[1] = AudioDuckingOutputSnapshot(deviceID: 1, uid: "one", elements: [1], values: failedMuteBefore.values, muted: true)
let invalidEvidence = Data("corrupt journal evidence".utf8)
try invalidEvidence.write(to: failedMuteDirectory.appendingPathComponent("recovery-v1.json"))
let failedMuteWrites = failedMuteOutput.writes.count
check(!failedMuteRuntime.observeMuteChange(token: failedMuteToken), "failed mute persistence refuses successful reconciliation")
check(failedMuteRuntime.failureReason == "journal_confirm_failed" && failedMuteRuntime.isQuarantined && failedMuteRuntime.status == .incomplete,
      "failed mute persistence quarantines its ownership cycle")
failedMuteRuntime.end(token: failedMuteToken, now: 1); failedMuteRuntime.tick(token: failedMuteToken, now: 5)
check(failedMuteOutput.writes.count == failedMuteWrites, "failed mute persistence never issues a cleanup setter")
let retainedInvalidEvidence = try Data(contentsOf: failedMuteDirectory.appendingPathComponent("recovery-v1.json"))
check(retainedInvalidEvidence == invalidEvidence, "failed mute persistence preserves unresolved durable evidence")
try FileManager.default.removeItem(at: failedMuteDirectory)
print("Durable mute-only journal, restart and persistence-failure checks passed")
