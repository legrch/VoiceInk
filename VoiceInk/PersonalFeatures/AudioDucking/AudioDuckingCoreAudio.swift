import CoreAudio
import AudioToolbox
import Foundation

/// All methods must be called by the same serialized owner. This adapter does
/// not schedule writes or decide whether a session still owns a control.
struct AudioDuckingCoreAudio {
    struct Snapshot {
        let device: AudioDeviceID
        let uid: String
        let elements: [UInt32]
        let values: [Float]
        let muted: Bool?
        let control: AudioDuckingOutputSnapshot.Control
        let stereoChannels: [UInt32]
        let balance: Float?
        let channelLayout: Data
    }

    private func address(_ selector: AudioObjectPropertySelector, element: UInt32 = 0,
                         scope: AudioObjectPropertyScope = kAudioDevicePropertyScopeOutput) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    func defaultDevice() -> AudioDeviceID? {
        var property = address(kAudioHardwarePropertyDefaultOutputDevice, scope: kAudioObjectPropertyScopeGlobal)
        var value = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size, &value)
        return status == noErr && value != kAudioObjectUnknown ? value : nil
    }

    /// Numeric device IDs can change across reconnect or restart. Resolve a
    /// persisted UID against current devices before any named recovery.
    func device(forUID expectedUID: String) -> AudioDeviceID? {
        var property = address(kAudioHardwarePropertyDevices, scope: kAudioObjectPropertyScopeGlobal)
        var bytes: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &property, 0, nil, &bytes) == noErr,
              bytes > 0, bytes % UInt32(MemoryLayout<AudioDeviceID>.size) == 0,
              bytes <= 65_536 else { return nil }
        var devices = [AudioDeviceID](repeating: 0, count: Int(bytes) / MemoryLayout<AudioDeviceID>.size)
        let status = devices.withUnsafeMutableBytes { buffer in
            AudioObjectGetPropertyData(system, &property, 0, nil, &bytes, buffer.baseAddress!)
        }
        guard status == noErr, Int(bytes) == devices.count * MemoryLayout<AudioDeviceID>.size else { return nil }
        let matches = devices.filter { uid(of: $0) == expectedUID }
        return matches.count == 1 ? matches[0] : nil
    }

    private func uid(of device: AudioDeviceID) -> String? {
        var property = address(kAudioDevicePropertyDeviceUID, scope: kAudioObjectPropertyScopeGlobal)
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        guard AudioObjectGetPropertyData(device, &property, 0, nil, &size, &value) == noErr else { return nil }
        return value as String
    }

    func currentOutputIdentity() -> (uid: String, name: String)? {
        guard let device = defaultDevice(), let identifier = uid(of: device), !identifier.isEmpty else { return nil }
        var property = address(kAudioObjectPropertyName, scope: kAudioObjectPropertyScopeGlobal)
        var name: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        guard AudioObjectGetPropertyData(device, &property, 0, nil, &size, &name) == noErr,
              defaultDevice() == device else { return nil }
        return (identifier, name as String)
    }

    private func writable(_ device: AudioDeviceID, element: UInt32, selector: AudioObjectPropertySelector) -> Bool {
        var property = address(selector, element: element)
        guard AudioObjectHasProperty(device, &property) else { return false }
        var settable = DarwinBoolean(false)
        return AudioObjectIsPropertySettable(device, &property, &settable) == noErr && settable.boolValue
    }

    private func volume(_ device: AudioDeviceID, element: UInt32, selector: AudioObjectPropertySelector) -> Float? {
        var property = address(selector, element: element)
        var value: Float = 0
        var size = UInt32(MemoryLayout<Float>.size)
        guard AudioObjectGetPropertyData(device, &property, 0, nil, &size, &value) == noErr,
              value.isFinite, (0...1).contains(value) else { return nil }
        return value
    }

    private func mute(_ device: AudioDeviceID) -> Bool? {
        var property = address(kAudioDevicePropertyMute)
        guard AudioObjectHasProperty(device, &property) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &property, 0, nil, &size, &value) == noErr else { return nil }
        return value != 0
    }

    private func virtualStereo(_ device: AudioDeviceID) -> (channels: [UInt32], balance: Float, layout: Data)? {
        var stream = address(kAudioDevicePropertyStreamConfiguration)
        var bytes: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &stream, 0, nil, &bytes) == noErr,
              bytes >= MemoryLayout<AudioBufferList>.size else { return nil }
        let memory = UnsafeMutableRawPointer.allocate(byteCount: Int(bytes), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { memory.deallocate() }
        guard AudioObjectGetPropertyData(device, &stream, 0, nil, &bytes, memory) == noErr else { return nil }
        let buffers = UnsafeMutableAudioBufferListPointer(memory.assumingMemoryBound(to: AudioBufferList.self))
        guard buffers.reduce(0, { $0 + Int($1.mNumberChannels) }) == 2 else { return nil }
        var stereo = address(kAudioDevicePropertyPreferredChannelsForStereo)
        var channels: [UInt32] = [0, 0]
        var channelBytes = UInt32(MemoryLayout<UInt32>.size * 2)
        guard AudioObjectGetPropertyData(device, &stereo, 0, nil, &channelBytes, &channels) == noErr,
              channelBytes == UInt32(MemoryLayout<UInt32>.size * 2),
              channels[0] != 0, channels[1] != 0, channels[0] != channels[1] else { return nil }
        var balanceProperty = address(kAudioHardwareServiceDeviceProperty_VirtualMainBalance)
        var balance: Float = 0
        var balanceBytes = UInt32(MemoryLayout<Float>.size)
        guard AudioObjectGetPropertyData(device, &balanceProperty, 0, nil, &balanceBytes, &balance) == noErr,
              balance.isFinite, (0...1).contains(balance) else { return nil }
        var layoutProperty = address(kAudioDevicePropertyPreferredChannelLayout)
        var layoutBytes: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &layoutProperty, 0, nil, &layoutBytes) == noErr,
              layoutBytes > 0, layoutBytes <= 4096 else { return nil }
        var layout = Data(count: Int(layoutBytes))
        let layoutStatus = layout.withUnsafeMutableBytes { raw in
            AudioObjectGetPropertyData(device, &layoutProperty, 0, nil, &layoutBytes, raw.baseAddress!)
        }
        guard layoutStatus == noErr, Int(layoutBytes) == layout.count else { return nil }
        return (channels, balance, layout)
    }

    /// Require an explicit stereo topology before considering per-channel
    /// setters. The caller confirms each channel independently.
    private func physicalStereo(_ device: AudioDeviceID) -> (channels: [UInt32], layout: Data)? {
        var stream = address(kAudioDevicePropertyStreamConfiguration)
        var bytes: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &stream, 0, nil, &bytes) == noErr,
              bytes >= MemoryLayout<AudioBufferList>.size, bytes <= 65_536 else { return nil }
        let memory = UnsafeMutableRawPointer.allocate(byteCount: Int(bytes), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { memory.deallocate() }
        guard AudioObjectGetPropertyData(device, &stream, 0, nil, &bytes, memory) == noErr else { return nil }
        let buffers = UnsafeMutableAudioBufferListPointer(memory.assumingMemoryBound(to: AudioBufferList.self))
        guard buffers.reduce(0, { $0 + Int($1.mNumberChannels) }) == 2 else { return nil }
        var stereo = address(kAudioDevicePropertyPreferredChannelsForStereo)
        var channels: [UInt32] = [0, 0]
        var channelBytes = UInt32(MemoryLayout<UInt32>.size * 2)
        guard AudioObjectGetPropertyData(device, &stereo, 0, nil, &channelBytes, &channels) == noErr,
              channelBytes == UInt32(MemoryLayout<UInt32>.size * 2),
              channels[0] != 0, channels[1] != 0, channels[0] != channels[1],
              channels.allSatisfy({ writable(device, element: $0, selector: kAudioDevicePropertyVolumeScalar) }) else { return nil }
        var property = address(kAudioDevicePropertyPreferredChannelLayout)
        var length: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &property, 0, nil, &length) == noErr,
              length > 0, length <= 4096 else { return nil }
        var layout = Data(count: Int(length))
        let status = layout.withUnsafeMutableBytes { raw in
            AudioObjectGetPropertyData(device, &property, 0, nil, &length, raw.baseAddress!)
        }
        guard status == noErr, Int(length) == layout.count else { return nil }
        return (channels, layout)
    }

    func snapshot() -> Snapshot? {
        guard let device = defaultDevice(), let result = snapshot(device: device), defaultDevice() == device else { return nil }
        return result
    }

    /// Named reads support bounded cleanup of the originally owned output.
    func snapshot(device: AudioDeviceID) -> Snapshot? {
        guard let uid = uid(of: device), !uid.isEmpty else { return nil }
        // The virtual main control is implemented by macOS and preserves the
        // relative balance of the selected hardware channels.
        let control: AudioDuckingOutputSnapshot.Control
        var channels: [UInt32] = []
        var balance: Float?
        var layout = Data()
        let selector: AudioObjectPropertySelector
        let elements: [UInt32]
        // Prefer actual controls over the virtual composite. The latter can
        // emit intermediate balance notifications while updating stereo volume.
        if writable(device, element: 0, selector: kAudioDevicePropertyVolumeScalar) {
            control = .physicalMain
            elements = [0]
            selector = kAudioDevicePropertyVolumeScalar
        } else if let stereo = physicalStereo(device) {
            control = .physicalChannels
            channels = stereo.channels
            elements = stereo.channels
            layout = stereo.layout
            selector = kAudioDevicePropertyVolumeScalar
        } else if writable(device, element: 0, selector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume),
                  let stereo = virtualStereo(device) {
            channels = stereo.channels
            balance = stereo.balance
            layout = stereo.layout
            control = .virtualMain
            elements = [0]
            selector = kAudioHardwareServiceDeviceProperty_VirtualMainVolume
        } else { return nil }
        let values = elements.compactMap { volume(device, element: $0, selector: selector) }
        guard values.count == elements.count else { return nil }
        return Snapshot(device: device, uid: uid, elements: elements, values: values, muted: mute(device), control: control, stereoChannels: channels, balance: balance, channelLayout: layout)
    }

    /// Returns success only for this individual write. The owner must read back
    /// the actual quantized value before claiming ownership.
    func setVolume(_ value: Float, device: AudioDeviceID, element: UInt32, expected: AudioDuckingOutputSnapshot) -> AudioDuckingWriteResult {
        guard value.isFinite, (0...1).contains(value), defaultDevice() == device else { return .notAttempted }
        return setOwnedVolume(value, device: device, element: element, expected: expected, requireDefault: true)
    }

    /// This does not grant ownership; only the coordinator's checked cleanup may call it.
    func setOwnedVolume(_ value: Float, device: AudioDeviceID, element: UInt32, expected: AudioDuckingOutputSnapshot, requireDefault: Bool = false) -> AudioDuckingWriteResult {
        guard value.isFinite, (0...1).contains(value), let selected = snapshot(device: device),
              selected.elements.contains(element), let current = convert(selected), current.hasSameControls(as: expected),
              current.muted == expected.muted, current.values == expected.values else { return .notAttempted }
        let selector = selected.control == .virtualMain ? kAudioHardwareServiceDeviceProperty_VirtualMainVolume : kAudioDevicePropertyVolumeScalar
        var property = address(selector, element: element)
        var mutableValue = value
        guard !requireDefault || defaultDevice() == device else { return .notAttempted }
        return .attempted(AudioObjectSetPropertyData(device, &property, 0, nil, UInt32(MemoryLayout<Float>.size), &mutableValue) == noErr)
    }
}

extension AudioDuckingCoreAudio: AudioDuckingOutput {
    var requiresWriteNotification: Bool { true }
    fileprivate func convert(_ value: Snapshot?) -> AudioDuckingOutputSnapshot? {
        value.map { AudioDuckingOutputSnapshot(deviceID: $0.device, uid: $0.uid, elements: $0.elements,
                                              values: $0.values, muted: $0.muted, control: $0.control,
                                              stereoChannels: $0.stereoChannels, balance: $0.balance, channelLayout: $0.channelLayout) }
    }

    func readDefault() -> AudioDuckingOutputSnapshot? { convert(snapshot()) }
    func readNamed(deviceID: UInt32) -> AudioDuckingOutputSnapshot? { convert(snapshot(device: deviceID)) }
    func canonicalTarget(deviceID: UInt32, element: UInt32, value: Float) -> Float? {
        // The HAL conversions describe units; they do not predict scalar
        // quantization. On some outputs the round-trip is not even identity.
        // Preserve the requested scalar and verify the actual notification.
        guard value.isFinite, (0...1).contains(value), defaultDevice() == deviceID else { return nil }
        return value
    }
    func writeDefault(deviceID: UInt32, element: UInt32, value: Float, expected: AudioDuckingOutputSnapshot) -> AudioDuckingWriteResult {
        setVolume(value, device: deviceID, element: element, expected: expected)
    }
    func writeOwnedDevice(deviceID: UInt32, element: UInt32, value: Float, expected: AudioDuckingOutputSnapshot) -> AudioDuckingWriteResult {
        setOwnedVolume(value, device: deviceID, element: element, expected: expected)
    }
}
