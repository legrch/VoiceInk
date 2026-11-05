import AppKit
import CoreAudio
import AudioToolbox
import Foundation
import os

/// Owns runtime and timer on one serial queue. No detached restoration waiter is
/// used, so cancellation of Recorder's waiter does not erase the obligation.
final class AudioDuckingService {
    private let queue = DispatchQueue(label: "voiceink.personal.audio-ducking")
    private let notificationQueue = DispatchQueue(label: "voiceink.personal.audio-ducking.events")
    private let latch = AudioDuckingEventLatch()
    private var runtime: AudioDuckingRuntime!
    private var journal: AudioDuckingRecoveryJournal?
    private var recovery: AudioDuckingRecoveryCoordinator?
    private var recordingVolume = AudioDuckingRecordingVolume()
    private var deferredVolumeObservation: (AudioDuckingLease.Token, AudioDuckingOutputSnapshot)?
    private var deferredStop: AudioDuckingLease.Token?
    private var deferredActivation: AudioDuckingLease.Token?
    private var deferredRetainedLevel: (AudioDuckingLease.Token, Double)?
    private var recoveryBlocked = false
    private var recoveryContinuityLost = false
    private var unsettledWrites = AudioDuckingUnsettledWrites()

    // Queue-confined, retained even when another output receives a fresh runtime.
    private func retainUnsettledWrites() {
        unsettledWrites.retain(runtime.quarantinedDeviceUID)
        if let recovery, case .incomplete = recovery.state {
            unsettledWrites.retain(recovery.unsettledDeviceUID)
        }
    }
    private let recoveryLatch = AudioDuckingEventLatch()
    private var recoveryToken: AudioDuckingLease.Token?
    private var recoveryTimer: DispatchSourceTimer?
    private var recoveryListeners: [(AudioDeviceID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var timer: DispatchSourceTimer?
    private var observer: NSObjectProtocol?
    private var terminateObserver: NSObjectProtocol?
    private var outputListener: AudioObjectPropertyListenerBlock?
    private var serviceRestartListener: AudioObjectPropertyListenerBlock?
    private var deviceListeners: [(AudioDeviceID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var outputListenerInstalled = false
    private let statusChanged: (AudioDuckingRuntime.Status) -> Void
    private let logger = Logger(subsystem: "com.prakashjoshipax.VoiceInk", category: "AudioDucking")
    private var lastReportedStatus: AudioDuckingRuntime.Status?
    private var lastReportedQuarantine: Bool?
    private var lastReportedAdjustmentID: UUID?
    var manualAdjustment: (id: UUID, uid: String, percent: Double)? { queue.sync { runtime.manualAdjustment } }
    private var outputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    private var serviceRestartAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyServiceRestarted,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    init(statusChanged: @escaping (AudioDuckingRuntime.Status) -> Void = { _ in }) {
        self.statusChanged = statusChanged
        let output = AudioDuckingCoreAudio()
        do {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            journal = try AudioDuckingRecoveryJournal(directory: base.appendingPathComponent("com.prakashjoshipax.VoiceInk/PersonalAudioDucking", isDirectory: true))
        } catch { recoveryBlocked = true }
        runtime = makeRuntime(output: output)
        if let journal {
            recovery = AudioDuckingRecoveryCoordinator(journal: journal, output: output, resolve: { output.device(forUID: $0) })
        }
        let callback: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.routeOccurred() }
        outputListener = callback
        outputListenerInstalled = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &outputAddress, notificationQueue, callback
        ) == noErr
        let restartCallback: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.audioServiceRestarted() }
        serviceRestartListener = restartCallback
        let restartInstalled = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &serviceRestartAddress, notificationQueue, restartCallback
        ) == noErr
        outputListenerInstalled = outputListenerInstalled && restartInstalled
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: nil
        ) { [weak self] _ in self?.sleepOccurred() }
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: nil
        ) { [weak self] _ in self?.terminate() }
        queue.async { [weak self] in self?.startRecovery() }
    }

    /// Every replacement runtime shares both lifecycle and queued recovery gates.
    /// recoveryBlocked is queue-confined; callbacks advance the event latch.
    private func makeRuntime(output: AudioDuckingCoreAudio) -> AudioDuckingRuntime {
        let eventLatch = latch
        return AudioDuckingRuntime(output: output, journal: journal,
            normalWriteAllowed: { [weak self] token in
                self?.recoveryBlocked == false && eventLatch.permits(token)
            }, writeAdmission: { [weak self] token, operation in
                guard self?.recoveryBlocked == false else { return .notAttempted }
                return eventLatch.performWrite(ifCurrent: token, operation)
            })
    }

    var effectiveConfiguration: AudioDuckingConfiguration? {
        queue.sync { runtime.effectiveConfiguration }
    }

    var hasOwnershipCycle: Bool { queue.sync { runtime.hasOwnershipCycle || recoveryBlocked } }
    private var selectedOutputBlocked: Bool {
        guard let identity = AudioDuckingCoreAudio().currentOutputIdentity() else { return false }
        guard unsettledWrites.allows(identity.uid), let journal else { return true }
        return (try? journal.isAcknowledgedDeviceBlocked(identity.uid)) != false
    }
    var isQuarantined: Bool {
        queue.sync {
            retainUnsettledWrites()
            return runtime.isQuarantined || recoveryBlocked || selectedOutputBlocked
        }
    }
    /// Recheck the actual delayed target, not the output selected at begin.
    /// New mute effects share quarantine and event ordering with ducking writes.
    func performLegacyMute(deviceID: AudioDeviceID, operation: () -> Bool) -> Bool {
        queue.sync {
            retainUnsettledWrites()
            guard !recoveryBlocked else { return false }
            let output = AudioDuckingCoreAudio()
            return RecordingMuteAdmission.perform(deviceID: deviceID, journal: journal,
                unsettled: unsettledWrites, latch: latch, readIdentity: {
                    guard let selected = output.defaultDevice(), let uid = output.uid(of: selected) else { return nil }
                    return (selected, uid)
                }, operation: operation)
        }
    }

    var currentOutputIdentity: (uid: String, name: String)? { queue.sync { AudioDuckingCoreAudio().currentOutputIdentity() } }

    var currentVolumeReading: (percent: Double, muted: Bool?, restorePercent: Double)? {
        queue.sync {
            guard let snapshot = AudioDuckingCoreAudio().readDefault(), let peak = snapshot.values.max() else { return nil }
            let saved = (try? journal?.pendingRecovery(for: snapshot.uid))?.1.baseline.max()
            let fallback = runtime.lease.baseline?.max() ?? saved ?? peak
            let original = recordingVolume.percent(forUID: snapshot.uid) ?? Double(fallback) * 100
            return (Double(peak) * 100, snapshot.muted, original)
        }
    }

    var canAcknowledgeRecovery: Bool {
        queue.sync {
            retainUnsettledWrites()
            guard recoveryToken == nil, !runtime.hasPendingWrite,
                  runtime.status != .active, runtime.status != .restoring,
                  let journal, let snapshot = AudioDuckingCoreAudio().readDefault(), snapshot.muted != nil else { return false }
            return unsettledWrites.allows(snapshot.uid) && (try? journal.pendingRecovery(for: snapshot.uid)) != nil
        }
    }

    /// Explicit reset archives unresolved records of the connected output.
    /// It never writes volume, restores baseline or confirms a previous setter.
    func acknowledgeRecovery(reason: AudioDuckingRecoveryJournal.AcknowledgmentReason = .userSetVolume) -> Bool {
        queue.sync {
            retainUnsettledWrites()
            guard recoveryToken == nil, !runtime.hasPendingWrite,
                  runtime.status != .active, runtime.status != .restoring, let journal else { return false }
            let epoch = latch.currentEpoch()
            let output = AudioDuckingCoreAudio()
            guard let snapshot = output.readDefault(), snapshot.muted != nil,
                  unsettledWrites.allows(snapshot.uid) else { return false }
            do {
                var accepted = false
                for _ in 0..<64 {
                    guard try journal.pendingRecovery(for: snapshot.uid) != nil else { break }
                    guard try journal.acknowledge(uid: snapshot.uid, observed: snapshot, now: Date(), reason: reason, commit: { operation in
                        guard let current = output.readDefault(), current.hasSameControls(as: snapshot),
                              current.muted == snapshot.muted,
                              AudioDuckingOutputSnapshot.levelsMatch(current.values, snapshot.values) else { return false }
                        return try self.latch.performIfCurrent(epoch) {
                            guard !self.runtime.hasPendingWrite, self.recoveryToken == nil else { return false }
                            try operation()
                            return true
                        } ?? false
                    }) else { return false }
                    accepted = true
                }
                guard accepted, try journal.pendingRecovery(for: snapshot.uid) == nil else { return false }
                timer?.cancel(); timer = nil
                recoveryTimer?.cancel(); recoveryTimer = nil
                if let token = runtime.lease.token { _ = latch.invalidate(ifCurrent: token); latch.clear(token) }
                removeDeviceListeners()
                runtime = makeRuntime(output: output)
                recoveryBlocked = false
                recoveryContinuityLost = false
                lastReportedStatus = nil
                logger.notice("Owner acknowledged recovery; observed UID and volume are private: uid=\(snapshot.uid, privacy: .private) values=\(String(describing: snapshot.values), privacy: .private) mute=\(String(describing: snapshot.muted), privacy: .private)")
                startRecovery()
                return true
            } catch { publishStatus(.incomplete); return false }
        }
    }

    func abandonUnownedSession() {
        queue.sync {
            guard !recoveryBlocked else { return }
            guard !runtime.hasOwnershipCycle, let token = runtime.lease.token else { return }
            timer?.cancel()
            timer = nil
            runtime.invalidate(token: token)
            latch.clear(token)
            publishStatus(runtime.status)
        }
    }

    /// Snapshot is taken synchronously at recording begin, before the 220 ms trigger.
    func begin(sessionID: UUID, desired: AudioDuckingConfiguration) -> AudioDuckingLease.Token? {
        queue.sync {
            let eventEpoch = latch.currentEpoch()
            retainUnsettledWrites()
            if let output = AudioDuckingCoreAudio().currentOutputIdentity(), !unsettledWrites.allows(output.uid) {
                publishStatus(.incomplete)
                return nil
            }
            guard !recoveryBlocked else { publishStatus(.incomplete); return nil }
            if runtime.hasPendingWrite || runtime.deferredBeginToken != nil {
                // Preserve the real in-flight operation and its listener. It
                // confirms on the old token, then hands ownership to the latest
                // recording. Capture and its 220 ms trigger remain independent.
                guard let current = runtime.lease.token,
                      latch.permits(current) || latch.isMutePaused(current) else { return nil }
                let token = runtime.begin(sessionID: sessionID, desired: desired)
                publishStatus(runtime.status)
                return token
            }
            timer?.cancel()
            timer = nil
            guard outputListenerInstalled else { publishStatus(.unavailable); return nil }
            guard let journal, let identity = AudioDuckingCoreAudio().currentOutputIdentity() else {
                publishStatus(.unavailable); return nil
            }
            do {
                guard try !journal.isAcknowledgedDeviceBlocked(identity.uid) else {
                    publishStatus(.incomplete); return nil
                }
            } catch {
                recoveryBlocked = true
                publishStatus(.incomplete)
                return nil
            }
            // An event callback may latch before it enqueues cleanup. Resolve it
            // here before a new begin can inherit the invalidated lease.
            if let pending = latch.pendingInvalidation(), runtime.lease.token == pending {
                runtime.invalidate(token: pending)
                latch.clear(pending)
            }
            // Invalidation can retire inherited ownership while leaving a durable
            // recovery obligation. Inventory again before a new cycle may exist.
            retainUnsettledWrites()
            guard let selected = AudioDuckingCoreAudio().currentOutputIdentity(),
                  unsettledWrites.allows(selected.uid) else { publishStatus(.incomplete); return nil }
            do {
                let inheritedCycle = runtime.hasOwnershipCycle ? runtime.lease.token?.cycleID : nil
                guard try journal.prepareRecordingCycle(inheriting: inheritedCycle, selectedUID: selected.uid) else {
                    recoveryBlocked = true; publishStatus(.incomplete); return nil
                }
            } catch { recoveryBlocked = true; publishStatus(.incomplete); return nil }
            guard let token = runtime.begin(sessionID: sessionID, desired: desired) else {
                publishStatus(runtime.status)
                return nil
            }
            guard let capturedUID = runtime.capturedOutput?.uid else {
                runtime.invalidate(token: token); publishStatus(.incomplete); return nil
            }
            do {
                guard try !journal.isAcknowledgedDeviceBlocked(capturedUID) else {
                    runtime.invalidate(token: token); publishStatus(.incomplete); return nil
                }
            } catch {
                runtime.invalidate(token: token); recoveryBlocked = true
                publishStatus(.incomplete); return nil
            }
            guard latch.admit(token, observedEpoch: eventEpoch) else {
                runtime.invalidate(token: token)
                publishStatus(runtime.status)
                return nil
            }
            guard let captured = runtime.capturedOutput, installDeviceListeners(snapshot: captured, token: token) else {
                _ = latch.invalidate(ifCurrent: token)
                runtime.invalidate(token: token)
                latch.clear(token)
                publishStatus(runtime.status == .incomplete ? .incomplete : .unavailable)
                return nil
            }
            publishStatus(runtime.status)
            return token
        }
    }

    func activate(token: AudioDuckingLease.Token) {
        queue.async { [weak self] in
            guard let self else { return }
            if self.runtime.deferredBeginToken == token {
                self.runtime.activate(token: token, now: ProcessInfo.processInfo.systemUptime)
                return
            }
            if self.latch.isMutePaused(token) { self.deferredActivation = token; return }
            guard self.latch.permits(token) else { return }
            guard !self.recoveryBlocked else {
                _ = self.latch.invalidate(ifCurrent: token)
                self.runtime.invalidate(token: token)
                self.publishStatus(.incomplete)
                return
            }
            self.runtime.activate(token: token, now: ProcessInfo.processInfo.systemUptime)
            self.publishStatus(self.runtime.status)
            self.schedule(token: token)
        }
    }

    func end(token: AudioDuckingLease.Token) {
        queue.async { [weak self] in
            guard let self else { return }
            if self.runtime.deferredBeginToken == token {
                self.runtime.end(token: token, now: ProcessInfo.processInfo.systemUptime)
                return
            }
            if self.latch.isMutePaused(token) { self.deferredStop = token; return }
            guard self.latch.permits(token) else { return }
            self.runtime.end(token: token, now: ProcessInfo.processInfo.systemUptime)
            self.publishStatus(self.runtime.status)
            self.schedule(token: token)
        }
    }

    func updateRetainedPercent(_ percent: Double) {
        queue.async { [weak self] in
            guard let self else { return }
            if let next = self.runtime.deferredBeginToken {
                self.runtime.updateRetainedPercent(percent, token: next, now: ProcessInfo.processInfo.systemUptime)
                return
            }
            guard let token = self.runtime.lease.token else { return }
            if self.latch.isMutePaused(token) { self.deferredRetainedLevel = (token, percent); return }
            guard self.latch.permits(token) else { return }
            self.runtime.updateRetainedPercent(percent, token: token, now: ProcessInfo.processInfo.systemUptime)
            self.publishStatus(self.runtime.status)
            self.schedule(token: token)
        }
    }

    func captureRecordingVolume() {
        queue.sync {
            guard let snapshot = AudioDuckingCoreAudio().readDefault() else { return }
            let inherited = runtime.capturedOutput.map { $0.hasSameControls(as: snapshot) } == true ? runtime.lease.baseline : nil
            recordingVolume.capture(snapshot, inherited: inherited)
        }
    }

    /// Pause before entering the serialized queue. Resume only this mute
    /// observation; route/sleep events advance the epoch and cannot be undone.
    private func muteEventOccurred(token: AudioDuckingLease.Token) {
        guard let epoch = latch.pause(ifCurrent: token) else { return }
        queue.async { [weak self] in
            guard let self, self.latch.currentEpoch() == epoch, self.runtime.lease.token == token else { return }
            guard self.runtime.observeMuteChange(token: token) else {
                self.logger.warning("Mute change could not retain ownership; pending=\(self.runtime.hasPendingWrite, privacy: .public)")
                self.enqueueInvalidation(token)
                return
            }
            guard self.latch.resume(token, after: epoch) else { return }
            // Stop is never dropped by a temporary pause and wins over delayed
            // activation/settings. Apply it before acknowledgements can advance
            // another fade-down write.
            let stopped = self.deferredStop == token
            var needsSchedule = stopped
            if stopped {
                self.deferredStop = nil
                self.deferredActivation = nil
                self.deferredRetainedLevel = nil
                self.runtime.end(token: token, now: ProcessInfo.processInfo.systemUptime)
            } else {
                if self.deferredActivation == token {
                    self.deferredActivation = nil
                    self.runtime.activate(token: token, now: ProcessInfo.processInfo.systemUptime)
                    needsSchedule = true
                }
                if let (levelToken, percent) = self.deferredRetainedLevel, levelToken == token {
                    self.deferredRetainedLevel = nil
                    self.runtime.updateRetainedPercent(percent, token: token, now: ProcessInfo.processInfo.systemUptime)
                    needsSchedule = true
                }
            }
            // Preserve a real volume notification delivered during this pause;
            // a mute notification alone never acknowledges an own volume write.
            if let (observedToken, observed) = self.deferredVolumeObservation, observedToken == token {
                self.deferredVolumeObservation = nil
                self.runtime.volumeChanged(token: token, now: ProcessInfo.processInfo.systemUptime, observed: observed)
            }
            if self.completeDeferredBeginIfReady() { return }
            self.publishStatus(self.runtime.status)
            if needsSchedule { self.schedule(token: token) }
        }
    }

    private func publishStatus(_ status: AudioDuckingRuntime.Status) {
        retainUnsettledWrites()
        let quarantined = runtime.isQuarantined || recoveryBlocked || selectedOutputBlocked
        guard lastReportedStatus != status || lastReportedQuarantine != quarantined || lastReportedAdjustmentID != runtime.manualAdjustment?.id else { return }
        lastReportedAdjustmentID = runtime.manualAdjustment?.id
        lastReportedStatus = status
        lastReportedQuarantine = quarantined
        if status == .incomplete || status == .unavailable {
            logger.warning("Audio status \(String(describing: status), privacy: .public), reason \(self.runtime.failureReason, privacy: .public)")
            if let levels = runtime.failureLevels {
                logger.warning("Audio scalar before=\(levels.before, privacy: .public) target=\(levels.target, privacy: .public) observed=\(levels.observed, privacy: .public)")
            }
        }
        statusChanged(status)
    }

    private func removeDeviceListeners() {
        deferredVolumeObservation = nil
        deferredStop = nil
        deferredActivation = nil
        deferredRetainedLevel = nil
        for (device, var address, callback) in deviceListeners {
            AudioObjectRemovePropertyListenerBlock(device, &address, notificationQueue, callback)
        }
        deviceListeners.removeAll()
    }

    private func installDeviceListeners(snapshot: AudioDuckingOutputSnapshot, token: AudioDuckingLease.Token) -> Bool {
        removeDeviceListeners()
        let device = snapshot.deviceID
        let properties: [(AudioObjectPropertySelector, AudioObjectPropertyScope)] = [
            (kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal),
            (kAudioDevicePropertyStreamConfiguration, kAudioDevicePropertyScopeOutput),
            (kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput)
        ]
        for (selector, scope) in properties {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: 0)
            guard AudioObjectHasProperty(device, &address) else { continue }
            let callback: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                if selector == kAudioDevicePropertyMute {
                    self?.muteEventOccurred(token: token)
                } else {
                    self?.deviceEventOccurred(token: token, reason: "device property \(selector)")
                }
            }
            guard AudioObjectAddPropertyListenerBlock(device, &address, notificationQueue, callback) == noErr else {
                removeDeviceListeners()
                return false
            }
            deviceListeners.append((device, address, callback))
        }
        if snapshot.control == .virtualMain || snapshot.control == .physicalChannels {
            var topologyProperties = [kAudioDevicePropertyPreferredChannelsForStereo, kAudioDevicePropertyPreferredChannelLayout]
            if snapshot.control == .virtualMain { topologyProperties.append(kAudioHardwareServiceDeviceProperty_VirtualMainBalance) }
            for selector in topologyProperties {
                var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput, mElement: 0)
                guard AudioObjectHasProperty(device, &address) else { removeDeviceListeners(); return false }
                let callback: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                    guard let current = AudioDuckingCoreAudio().readDefault() else {
                        self?.deviceEventOccurred(token: token, reason: "topology property \(selector), output snapshot unavailable")
                        return
                    }
                    guard current.hasSameControls(as: snapshot) else {
                        let sameDevice = current.deviceID == snapshot.deviceID && current.uid == snapshot.uid
                        let sameKind = current.control == snapshot.control && current.elements == snapshot.elements
                        let sameChannels = current.stereoChannels == snapshot.stereoChannels
                        let sameLayout = current.channelLayout == snapshot.channelLayout
                        let before = snapshot.balance.map(String.init(describing:)) ?? "unavailable"
                        let after = current.balance.map(String.init(describing:)) ?? "unavailable"
                        self?.deviceEventOccurred(token: token, reason: "topology property \(selector), sameDevice=\(sameDevice), sameControl=\(sameKind), sameChannels=\(sameChannels), sameLayout=\(sameLayout), balanceBefore=\(before), balanceAfter=\(after)")
                        return
                    }
                }
                guard AudioObjectAddPropertyListenerBlock(device, &address, notificationQueue, callback) == noErr else {
                    removeDeviceListeners()
                    return false
                }
                deviceListeners.append((device, address, callback))
            }
        }
        let selector = snapshot.control == .virtualMain ? kAudioHardwareServiceDeviceProperty_VirtualMainVolume : kAudioDevicePropertyVolumeScalar
        let volumeCallback: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            // Capture at callback delivery, not later when the owner queue runs.
            guard let observed = AudioDuckingCoreAudio().readDefault() else {
                self?.deviceEventOccurred(token: token, reason: "volume notification unreadable")
                return
            }
            self?.queue.async { [weak self] in
                guard let self else { return }
                if self.latch.isMutePaused(token) {
                    self.deferredVolumeObservation = (token, observed)
                    return
                }
                guard self.latch.permits(token) else { return }
                self.runtime.volumeChanged(token: token, now: ProcessInfo.processInfo.systemUptime, observed: observed)
                if self.completeDeferredBeginIfReady() { return }
                self.publishStatus(self.runtime.status)
            }
        }
        for element in snapshot.elements {
            var volume = AudioObjectPropertyAddress(mSelector: selector,
                                                    mScope: kAudioDevicePropertyScopeOutput, mElement: element)
            guard AudioObjectHasProperty(device, &volume),
                  AudioObjectAddPropertyListenerBlock(device, &volume, notificationQueue, volumeCallback) == noErr else {
                removeDeviceListeners()
                return false
            }
            deviceListeners.append((device, volume, volumeCallback))
        }
        return true
    }

    /// The original timer remains responsible for the pending-write timeout.
    /// Only a genuine acknowledgement reaches this handoff; readback alone does
    /// not retire an uncertain write or bypass lifecycle quarantine.
    private func completeDeferredBeginIfReady() -> Bool {
        guard runtime.deferredBeginReady, let previous = runtime.lease.token,
              latch.permits(previous) else { return false }
        let next = runtime.completeDeferredBegin(now: ProcessInfo.processInfo.systemUptime) { old, new, snapshot in
            guard self.latch.handoff(from: old, to: new) else { return false }
            guard self.installDeviceListeners(snapshot: snapshot, token: new) else {
                _ = self.latch.invalidate(ifCurrent: new)
                self.latch.clear(new)
                return false
            }
            return true
        }
        if let next {
            logger.notice("Pending volume write confirmed; ownership handed to the latest recording")
            schedule(token: next)
        } else if runtime.deferredBeginToken != nil {
            // A mute observation may pause the latch between the readiness
            // check and runtime admission. Keep the old timer/listener alive;
            // only that observation's validated resume may retry the handoff.
            return false
        } else {
            timer?.cancel()
            timer = nil
            _ = latch.invalidate(ifCurrent: previous)
            latch.clear(previous)
        }
        publishStatus(runtime.status)
        return true
    }

    private func schedule(token: AudioDuckingLease.Token) {
        timer?.cancel()
        timer = nil
        guard runtime.status == .active || runtime.status == .restoring else {
            latch.clear(token)
            return
        }
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now(), repeating: .milliseconds(20), leeway: .milliseconds(5))
        source.setEventHandler { [weak self] in
            guard let self, self.latch.permits(token) else { return }
            let now = ProcessInfo.processInfo.systemUptime
            self.runtime.tick(token: token, now: now)
            if self.completeDeferredBeginIfReady() { return }
            self.publishStatus(self.runtime.status)
            if self.runtime.status == .active, !self.runtime.hasPendingWrite,
               self.runtime.transitionSettled {
                self.timer?.cancel()
                self.timer = nil
                return
            }
            if self.runtime.status != .active && self.runtime.status != .restoring {
                self.timer?.cancel()
                self.timer = nil
                self.latch.clear(token)
            }
        }
        timer = source
        source.resume()
    }

    private func routeOccurred() {
        let token = latch.invalidate()
        _ = recoveryLatch.invalidate()
        logger.warning("Default output notification")
        queue.async { [weak self] in
            guard let self else { return }
            self.scheduleRecoveryObservation()
            // Notify the settings view even when status remains idle.
            self.lastReportedStatus = nil
            if self.recoveryToken != nil {
                self.cancelRecovery()
                return
            }
            if let token, self.runtime.lease.token == token {
                self.timer?.cancel()
                self.timer = nil
                self.runtime.invalidate(token: token)
                self.latch.clear(token)
            }
            if self.recoveryContinuityLost { _ = self.holdOtherOutputRecoveryIfPossible() }
            guard !self.recoveryContinuityLost else { self.publishStatus(.incomplete); return }
            self.startRecovery()
        }
    }

    private func sleepOccurred() {
        let token = latch.invalidate()
        _ = recoveryLatch.invalidate()
        logger.warning("System sleep notification")
        queue.async { [weak self] in
            guard let self else { return }
            self.scheduleRecoveryObservation()
            self.cancelRecovery()
            if let token, self.runtime.lease.token == token {
                self.timer?.cancel()
                self.timer = nil
                self.runtime.invalidate(token: token)
                self.latch.clear(token)
            }
            // Do not automatically replay a write after an unobserved sleep.
            if let journal = self.journal, case .record = try? journal.read() {
                self.recoveryBlocked = true
                self.recoveryContinuityLost = true
            }
            self.publishStatus(self.recoveryBlocked ? .incomplete : self.runtime.status)
        }
    }

    private func audioServiceRestarted() {
        let token = latch.invalidate()
        _ = recoveryLatch.invalidate()
        logger.warning("Core Audio service restart notification")
        queue.async { [weak self] in
            guard let self else { return }
            self.scheduleRecoveryObservation()
            self.outputListenerInstalled = false
            self.cancelRecovery()
            if let token, self.runtime.lease.token == token {
                self.timer?.cancel()
                self.timer = nil
                self.runtime.invalidate(token: token)
                self.latch.clear(token)
            }
            self.recoveryBlocked = true
            self.recoveryContinuityLost = true
            self.publishStatus(.incomplete)
        }
    }

    private func deviceEventOccurred(token: AudioDuckingLease.Token, reason: String) {
        guard latch.invalidate(ifCurrent: token) else { return }
        logger.warning("Audio output invalidated: \(reason, privacy: .public)")
        enqueueInvalidation(token)
    }

    /// A delayed read is diagnostic only. It does not cancel an outstanding
    /// HAL write, authorize recovery, or remove the durable record.
    private func scheduleRecoveryObservation() {
        queue.asyncAfter(deadline: .now() + .milliseconds(400)) { [weak self] in
            guard let self, let journal = self.journal,
                  case .record(let record) = try? journal.read() else { return }
            let output = AudioDuckingCoreAudio()
            guard let device = output.device(forUID: record.deviceUID) else {
                self.logger.warning("Recovery observation: device missing, phase=\(record.phase.rawValue, privacy: .public)")
                return
            }
            let observation = record.observe(output.readNamed(deviceID: device))
            self.logger.warning("Recovery observation: \(observation.rawValue, privacy: .public), phase=\(record.phase.rawValue, privacy: .public)")
        }
    }

    private func enqueueInvalidation(_ token: AudioDuckingLease.Token?) {
        queue.async { [weak self] in
            guard let self, let token, self.runtime.lease.token == token else { return }
            self.timer?.cancel()
            self.timer = nil
            self.runtime.invalidate(token: token)
            if let journal = self.journal, case .record = try? journal.read() {
                self.recoveryBlocked = true
                self.recoveryContinuityLost = true
            }
            self.latch.clear(token)
            if self.holdOtherOutputRecoveryIfPossible() { self.publishStatus(.idle) }
            else { self.publishStatus(self.runtime.status) }
            self.scheduleRecoveryObservation()
        }
    }

    /// Preserve another output's evidence without quarantining the selected
    /// output. Its own UID remains blocked, including while it is connected.
    private func holdOtherOutputRecoveryIfPossible() -> Bool {
        retainUnsettledWrites()
        guard recoveryToken == nil, !runtime.hasPendingWrite,
              runtime.status != .active, runtime.status != .restoring,
              let journal, case .record(let record) = try? journal.read(),
              let identity = AudioDuckingCoreAudio().currentOutputIdentity(),
              identity.uid != record.deviceUID else { return false }
        do {
            try journal.holdMissingDevice(record)
            timer?.cancel(); timer = nil
            if let token = runtime.lease.token { _ = latch.invalidate(ifCurrent: token); latch.clear(token) }
            removeDeviceListeners()
            runtime = makeRuntime(output: AudioDuckingCoreAudio())
            recoveryBlocked = false
            recoveryContinuityLost = false
            return true
        } catch { recoveryBlocked = true; return false }
    }

    /// The queue serializes startup and route recovery against new sessions.
    private func startRecovery() {
        guard let recovery else { recoveryBlocked = true; publishStatus(.incomplete); return }
        _ = holdOtherOutputRecoveryIfPossible()
        recovery.prepare()
        switch recovery.state {
        case .idle:
            recoveryBlocked = false
            publishStatus(.idle)
        case .incomplete, .waiting:
            recoveryBlocked = true
            recoveryContinuityLost = true
            publishStatus(.incomplete)
        case .deferredMissing:
            // The TTL bounds waiting, not uncertainty. Reconnection never
            // authorizes a write to an output whose continuity was lost.
            recoveryBlocked = true
            recoveryContinuityLost = true
            publishStatus(.incomplete)
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now() + .seconds(30))
            source.setEventHandler { [weak self] in
                guard let self else { return }
                self.recovery?.tick(now: ProcessInfo.processInfo.systemUptime)
                self.handleRecoveryState()
            }
            recoveryTimer = source
            source.resume()
        case .needsListener(let plan):
            recoveryBlocked = true
            guard outputListenerInstalled else { recovery.invalidate(); publishStatus(.incomplete); return }
            var lease = AudioDuckingLease()
            let token = lease.begin(UUID())
            let epoch = recoveryLatch.currentEpoch()
            guard recoveryLatch.admit(token, observedEpoch: epoch), installRecoveryListeners(plan: plan, token: token) else {
                recovery.invalidate()
                publishStatus(.incomplete)
                return
            }
            recoveryToken = token
            recovery.issue(now: ProcessInfo.processInfo.systemUptime,
                allowed: { self.recoveryLatch.permits(token) },
                writeAdmission: { self.recoveryLatch.performWrite(ifCurrent: token, $0) })
            handleRecoveryState()
            if case .waiting = recovery.state {
                let source = DispatchSource.makeTimerSource(queue: queue)
                source.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100))
                source.setEventHandler { [weak self] in
                    guard let self, self.recoveryLatch.permits(token) else { return }
                    self.recovery?.tick(now: ProcessInfo.processInfo.systemUptime)
                    self.handleRecoveryState()
                }
                recoveryTimer = source
                source.resume()
            }
        }
    }

    private func installRecoveryListeners(plan: AudioDuckingRecoveryCoordinator.Plan, token: AudioDuckingLease.Token) -> Bool {
        removeRecoveryListeners()
        let device = plan.snapshot.deviceID
        let volume = plan.snapshot.control == .virtualMain ? kAudioHardwareServiceDeviceProperty_VirtualMainVolume : kAudioDevicePropertyVolumeScalar
        var properties: [(AudioObjectPropertySelector, AudioObjectPropertyScope)] = [
            (volume, kAudioObjectPropertyScopeOutput),
            (kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal),
            (kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeOutput),
            (kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput)
        ]
        if plan.snapshot.control == .virtualMain {
            properties += [(kAudioDevicePropertyPreferredChannelsForStereo, kAudioObjectPropertyScopeOutput),
                           (kAudioDevicePropertyPreferredChannelLayout, kAudioObjectPropertyScopeOutput),
                           (kAudioHardwareServiceDeviceProperty_VirtualMainBalance, kAudioObjectPropertyScopeOutput)]
        }
        for (selector, scope) in properties {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: 0)
            if !AudioObjectHasProperty(device, &address) {
                if selector == kAudioDevicePropertyMute { continue }
                removeRecoveryListeners(); return false
            }
            let callback: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                guard let self else { return }
                let observed = AudioDuckingCoreAudio().readNamed(deviceID: device)
                guard let observed, observed.hasSameControls(as: plan.snapshot), observed.muted == plan.snapshot.muted else {
                    self.recoveryEventOccurred(token: token)
                    return
                }
                self.queue.async { [weak self] in
                    guard let self, self.recoveryLatch.permits(token) else { return }
                    self.recovery?.notified(now: ProcessInfo.processInfo.systemUptime)
                    self.handleRecoveryState()
                }
            }
            guard AudioObjectAddPropertyListenerBlock(device, &address, notificationQueue, callback) == noErr else {
                removeRecoveryListeners(); return false
            }
            recoveryListeners.append((device, address, callback))
        }
        return true
    }

    private func recoveryEventOccurred(token: AudioDuckingLease.Token) {
        guard recoveryLatch.invalidate(ifCurrent: token) else { return }
        queue.async { [weak self] in self?.cancelRecovery() }
    }

    private func handleRecoveryState() {
        guard let recovery else { return }
        switch recovery.state {
        case .idle:
            recoveryBlocked = false
            finishRecoveryListeners()
            publishStatus(.idle)
        case .incomplete:
            recoveryBlocked = true
            recoveryContinuityLost = true
            finishRecoveryListeners()
            publishStatus(.incomplete)
        case .needsListener, .waiting, .deferredMissing: break
        }
    }

    private func cancelRecovery() {
        guard recoveryToken != nil else { return }
        recovery?.invalidate()
        recoveryBlocked = true
        recoveryContinuityLost = true
        finishRecoveryListeners()
        publishStatus(.incomplete)
    }

    private func finishRecoveryListeners() {
        recoveryTimer?.cancel()
        recoveryTimer = nil
        if let token = recoveryToken { recoveryLatch.clear(token) }
        recoveryToken = nil
        removeRecoveryListeners()
    }

    private func removeRecoveryListeners() {
        for (device, var address, callback) in recoveryListeners {
            AudioObjectRemovePropertyListenerBlock(device, &address, notificationQueue, callback)
        }
        recoveryListeners.removeAll()
    }

    private func terminate() {
        let token = latch.invalidate()
        queue.sync {
            timer?.cancel()
            timer = nil
            _ = recoveryLatch.invalidate()
            cancelRecovery()
            if let token { runtime.invalidate(token: token); latch.clear(token) }
        }
    }

    deinit {
        removeDeviceListeners()
        removeRecoveryListeners()
        if let outputListener {
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &outputAddress,
                                                   notificationQueue, outputListener)
        }
        if let serviceRestartListener {
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &serviceRestartAddress,
                                                   notificationQueue, serviceRestartListener)
        }
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        if let terminateObserver { NotificationCenter.default.removeObserver(terminateObserver) }
        timer?.cancel()
    }
}
