import CoreAudio
import Foundation

@MainActor
final class MediaController: ObservableObject {

    static let shared = MediaController()
    let duckingSettings = AudioDuckingSettings()
    @Published private(set) var duckingStatus: AudioDuckingRuntime.Status = .idle
    @Published private(set) var incompleteDuckingRestoration = false
    @Published private(set) var duckingQuarantined = false
    @Published private(set) var canAcknowledgeDuckingRecovery = false
    @Published private(set) var audioOutputUID: String?
    @Published private(set) var audioOutputName: String?
    @Published private(set) var currentOutputVolumePercent: Double?
    @Published private(set) var currentOutputMuted = false
    @Published private(set) var outputRestoreVolumePercent: Double?
    private var duckingService: AudioDuckingService?
    private var duckingToken: AudioDuckingLease.Token?
    private var lastManualAdjustmentID: UUID?
    private var effectiveMode: AudioDuckingConfiguration.Mode = .unchanged

    var duckingConfigurationPending: Bool {
        if let effective = duckingService?.effectiveConfiguration {
            var desired = duckingSettings.configuration
            // Retained level is applied live; other fields take effect after
            // the current ownership cycle is finished.
            desired.retainedPercent = effective.retainedPercent
            desired.retainedPercentByDevice = effective.retainedPercentByDevice
            return effective != desired
        }
        return muteOwnership.hasDevices && duckingSettings.configuration.mode != .mute
    }

    // Keep responsibility across rapid recordings, including output-device changes.
    private var muteOwnership = RecordingMuteOwnership()
    private var recordingSessionID = UUID()

    @Published var isSystemMuteEnabled: Bool = UserDefaults.standard.bool(forKey: "isSystemMuteEnabled") {
        didSet { UserDefaults.standard.set(isSystemMuteEnabled, forKey: "isSystemMuteEnabled") }
    }

    @Published var audioResumptionDelay: Double = UserDefaults.standard.double(forKey: "audioResumptionDelay") {
        didSet { UserDefaults.standard.set(audioResumptionDelay, forKey: "audioResumptionDelay") }
    }

    private init() { ensureDuckingService() }

    private func ensureDuckingService() {
        guard duckingService == nil else { return }
        duckingService = AudioDuckingService { [weak self] status in
            Task { @MainActor in
                self?.duckingStatus = status
                self?.duckingQuarantined = self?.duckingService?.isQuarantined == true
                self?.canAcknowledgeDuckingRecovery = self?.duckingService?.canAcknowledgeRecovery == true
                let identity = self?.duckingService?.currentOutputIdentity
                self?.audioOutputUID = identity?.uid
                self?.audioOutputName = identity?.name
                if let self, let adjustment = self.duckingService?.manualAdjustment, self.lastManualAdjustmentID != adjustment.id {
                    self.lastManualAdjustmentID = adjustment.id
                    var desired = self.duckingSettings.configuration
                    desired.setRetainedPercent(adjustment.percent.rounded(), for: adjustment.uid)
                    self.duckingSettings.set(desired)
                }
                self?.incompleteDuckingRestoration = status == .incomplete
            }
        }
    }

    var isIdleForAppSwitch: Bool { duckingService?.isIdleForAppSwitch ?? true }

    func refreshOutputVolume() {
        // Output identity and readiness may become readable after the route
        // callback, without another status transition.
        let identity = duckingService?.currentOutputIdentity
        audioOutputUID = identity?.uid
        audioOutputName = identity?.name
        duckingQuarantined = duckingService?.isQuarantined == true
        canAcknowledgeDuckingRecovery = duckingService?.canAcknowledgeRecovery == true
        let reading = duckingService?.currentVolumeReading
        currentOutputVolumePercent = reading?.percent
        outputRestoreVolumePercent = reading?.restorePercent
        currentOutputMuted = reading?.muted == true
    }

    func updateDuckingLevel(_ percent: Double) {
        duckingService?.updateRetainedPercent(percent)
    }

    func beginRecordingSession(sessionID: UUID) {
        // Invalidate delayed restoration before the recorder's 220 ms mute delay.
        recordingSessionID = sessionID
        muteOwnership.begin(sessionID)
        duckingService?.prepareRecordingCapture(sessionID: sessionID)
        duckingService?.captureRecordingVolume()
        let desired = duckingSettings.configuration
        if duckingService?.isQuarantined == true {
            // An outstanding HAL effect cannot be cancelled. Do not start a
            // competing mute or another duck cycle until the service is reset.
            effectiveMode = .unchanged
        } else if duckingService?.hasOwnershipCycle == true {
            effectiveMode = .duck
        } else if muteOwnership.hasDevices {
            effectiveMode = .mute
        } else {
            effectiveMode = desired.mode
        }
        if effectiveMode == .duck {
            ensureDuckingService()
            duckingToken = duckingService?.begin(sessionID: sessionID, desired: desired)
            // Cleanup can finish between choosing the inherited cycle and the
            // serialized begin. In that case honor the newly effective mode.
            if let effective = duckingService?.effectiveConfiguration, effective.mode != .duck,
               duckingService?.hasOwnershipCycle == false {
                duckingService?.abandonUnownedSession()
                duckingToken = nil
                effectiveMode = effective.mode
            } else if duckingToken == nil, duckingService?.hasOwnershipCycle == false, desired.mode != .duck {
                effectiveMode = desired.mode
            }
        } else {
            duckingService?.abandonUnownedSession()
            duckingToken = nil
        }
    }

    func recordingCaptureEnded(sessionID: UUID) {
        guard sessionID == recordingSessionID else { return }
        duckingService?.recordingCaptureEnded(sessionID: sessionID)
    }

    func resetDuckingWhenIdle() {
        _ = duckingService?.resetIdleOutput()
        refreshOutputVolume()
    }

    @discardableResult
    func acknowledgeDuckingRecovery(reason: AudioDuckingRecoveryJournal.AcknowledgmentReason = .userSetVolume) -> Bool {
        guard duckingService?.acknowledgeRecovery(reason: reason) == true else { return false }
        canAcknowledgeDuckingRecovery = false
        incompleteDuckingRestoration = false
        duckingQuarantined = false
        return true
    }

    func dismissIncompleteDuckingRestoration() {
        incompleteDuckingRestoration = false
    }

    func muteSystemAudio(sessionID: UUID) -> Bool {
        guard sessionID == recordingSessionID, !Task.isCancelled else { return false }
        if effectiveMode == .duck {
            guard let duckingToken else { return false }
            duckingService?.activate(token: duckingToken)
            return true
        }
        guard effectiveMode == .mute else { return false }
        guard let deviceID = getDefaultOutputDevice(),
            let currentlyMuted = isSystemAudioMuted(deviceID: deviceID) else {
            return false
        }
        // A device already muted by the user is never added to our ownership.
        guard !currentlyMuted else { return true }
        guard duckingService?.performLegacyMute(deviceID: deviceID, operation: {
            self.setSystemMuted(true, deviceID: deviceID)
        }) == true else {
            return false
        }
        objectWillChange.send()
        muteOwnership.recordMuted(deviceID)
        return true
    }

    func unmuteSystemAudio(sessionID: UUID) async {
        guard sessionID == recordingSessionID, !Task.isCancelled else { return }
        if effectiveMode == .duck, let duckingToken {
            duckingService?.end(token: duckingToken)
        }
        // Restoration follows actual mute ownership, never the newly selected
        // mode. Quarantine prevents new effects but does not erase this duty.
        guard muteOwnership.hasDevices else { return }
        let delay = audioResumptionDelay
        let delayNanoseconds = AudioDelay.restorationNanoseconds(delay)
        if delayNanoseconds > 0 {
            do {
                try await Task.sleep(nanoseconds: delayNanoseconds)
            } catch {
                return
            }
        }
        guard sessionID == recordingSessionID, !Task.isCancelled else { return }

        // Restore the devices we actually muted, rather than the current default.
        // Restore ownership even if the preference was disabled during recording.
        for deviceID in muteOwnership.restorationDevices(for: sessionID, cancelled: Task.isCancelled) {
            if setSystemMuted(false, deviceID: deviceID) {
                objectWillChange.send()
                muteOwnership.didRestore(deviceID)
            }
        }
    }

    private func getDefaultOutputDevice() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &propertySize,
            &deviceID
        )

        return status == noErr && deviceID != kAudioObjectUnknown ? deviceID : nil
    }

    private func isSystemAudioMuted(deviceID: AudioDeviceID) -> Bool? {
        var muted: UInt32 = 0
        var propertySize = UInt32(MemoryLayout<UInt32>.size)

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        if !AudioObjectHasProperty(deviceID, &address) {
            address.mElement = 0
            if !AudioObjectHasProperty(deviceID, &address) { return nil }
        }

        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &propertySize, &muted)
        return status == noErr ? muted != 0 : nil
    }

    private func setSystemMuted(_ muted: Bool, deviceID: AudioDeviceID) -> Bool {
        var muteValue: UInt32 = muted ? 1 : 0
        let propertySize = UInt32(MemoryLayout<UInt32>.size)

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        if !AudioObjectHasProperty(deviceID, &address) {
            address.mElement = 0
            if !AudioObjectHasProperty(deviceID, &address) { return false }
        }

        var isSettable: DarwinBoolean = false
        var status = AudioObjectIsPropertySettable(deviceID, &address, &isSettable)
        if status != noErr || !isSettable.boolValue { return false }

        status = AudioObjectSetPropertyData(deviceID, &address, 0, nil, propertySize, &muteValue)
        return status == noErr
    }
}
