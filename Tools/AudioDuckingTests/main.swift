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
    func readDefault() -> AudioDuckingOutputSnapshot? { hideDefault ? nil : devices[selected] }
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
check(abs((overrideRuntime.manualAdjustment?.percent ?? 0) - 66.6667) < 0.001, "manual volume is converted to retained percentage")
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
