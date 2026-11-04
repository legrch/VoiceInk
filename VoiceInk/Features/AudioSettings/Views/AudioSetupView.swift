import CoreAudio
import Combine
import SwiftUI

@MainActor
struct AudioSetupView: View {
    @ObservedObject private var audioDeviceManager = AudioDeviceManager.shared
    @ObservedObject private var mediaController = MediaController.shared
    @ObservedObject private var duckingSettings = MediaController.shared.duckingSettings
    @ObservedObject private var playbackController = PlaybackController.shared
    @State private var microphoneSourceBeforePriorityOrder: MicrophoneSourceSelection = .systemDefault
    @State private var refreshIconRotation = 0.0

    var body: some View {
        Form {
            Section {
                inputSettingsRows
            } header: {
                Text("Audio Input")
            }

            if usesPriorityOrder {
                Section {
                    priorityOrderRows
                } header: {
                    Text("Priority Order")
                }
            }

            Section {
                CustomSoundSettingsView()
            } header: {
                Text("Recording Sounds")
            }

            Section {
                Toggle("Mute Audio While Recording", isOn: muteEnabled)
                Toggle("Pause Media While Recording", isOn: $playbackController.isPauseMediaEnabled)

                LabeledContent("Resume Delay") {
                    resumeDelayMenu
                        .disabled(!canEditResumeDelay)
                }
                .foregroundStyle(canEditResumeDelay ? .primary : .secondary)
            } header: {
                Text("Recording Behavior")
            }

            Section {
                Toggle("Lower Audio While Recording", isOn: duckingEnabled)

                if duckingSettings.configuration.mode == .duck {
                    if let name = mediaController.audioOutputName {
                        LabeledContent("Current Output", value: name)
                    }
                    if let original = mediaController.outputRestoreVolumePercent {
                        LabeledContent("Volume After Recording", value: "\(Int(original.rounded())) %")
                    }
                    LabeledContent("Current Volume") {
                        if let percent = mediaController.currentOutputVolumePercent {
                            Text(mediaController.currentOutputMuted ? "Muted" : "\(Int(percent.rounded())) %")
                                .monospacedDigit()
                        } else {
                            Text("Unavailable").foregroundStyle(.secondary)
                        }
                    }
                    HStack {
                        Text("Volume During Recording")
                        Slider(value: deviceRetainedPercent, in: 0...100, step: 1)
                        TextField("", value: deviceRetainedPercent, format: .number)
                            .frame(width: 55)
                            .accessibilityLabel("Retained volume percent")
                        Text("%")
                    }
                    duckingSeconds("Fade Duration", keyPath: \.fadeDownSeconds)
                    duckingSeconds("Delay Before Restoring", keyPath: \.restoreDelaySeconds)
                    if playbackController.isPauseMediaEnabled {
                        Text("Turn off Pause Media While Recording to keep music playing during dictation.")
                            .foregroundStyle(.secondary)
                    }
                }

                if duckingSettings.invalidStoredConfiguration {
                    Text("Saved audio settings could not be read. Audio is unchanged until you choose new settings.")
                        .foregroundStyle(.orange)
                }
                if mediaController.duckingConfigurationPending {
                    Text("Audio changes take effect after the current restoration finishes.")
                        .foregroundStyle(.secondary)
                }
                if mediaController.duckingQuarantined || mediaController.canAcknowledgeDuckingRecovery {
                    HStack {
                        Text("Volume control is paused. Check your output volume before resuming.")
                            .foregroundStyle(.secondary)
                        if mediaController.canAcknowledgeDuckingRecovery {
                            Button("Resume") { mediaController.acknowledgeDuckingRecovery() }
                        }
                    }
                } else if mediaController.duckingStatus == .unavailable {
                    Text("Audio ducking is unavailable for the current output.")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Audio Ducking")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .onReceive(Timer.publish(every: 0.3, on: .main, in: .common).autoconnect()) { _ in
            mediaController.refreshOutputVolume()
        }
        .onAppear {
            mediaController.refreshOutputVolume()
            if !usesPriorityOrder {
                microphoneSourceBeforePriorityOrder = currentMicrophoneSource
            }
        }
    }

    private func setAudioMode(_ mode: AudioDuckingConfiguration.Mode) {
        var value = duckingSettings.configuration
        value.mode = mode
        if duckingSettings.set(value) {
            mediaController.isSystemMuteEnabled = mode == .mute
        }
    }

    private var duckingEnabled: Binding<Bool> {
        Binding(get: { duckingSettings.configuration.mode == .duck }, set: { enabled in
            if enabled { setAudioMode(.duck) }
            else if duckingSettings.configuration.mode == .duck { setAudioMode(.unchanged) }
        })
    }

    private var muteEnabled: Binding<Bool> {
        Binding(get: { duckingSettings.configuration.mode == .mute }, set: { enabled in
            if enabled { setAudioMode(.mute) }
            else if duckingSettings.configuration.mode == .mute { setAudioMode(.unchanged) }
        })
    }

    private func duckingValue(_ keyPath: WritableKeyPath<AudioDuckingConfiguration, Double>) -> Binding<Double> {
        Binding(get: { duckingSettings.configuration[keyPath: keyPath] }, set: { newValue in
            var value = duckingSettings.configuration
            value[keyPath: keyPath] = newValue
            duckingSettings.set(value)
        })
    }

    private var deviceRetainedPercent: Binding<Double> {
        Binding(get: { duckingSettings.configuration.retainedPercent(for: mediaController.audioOutputUID) }, set: { newValue in
            var value = duckingSettings.configuration
            value.setRetainedPercent(newValue, for: mediaController.audioOutputUID)
            if duckingSettings.set(value) { mediaController.updateDuckingLevel(newValue) }
        })
    }

    private func duckingSeconds(_ title: LocalizedStringKey, keyPath: WritableKeyPath<AudioDuckingConfiguration, Double>) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField("", value: duckingValue(keyPath), format: .number.precision(.fractionLength(1)))
                .frame(width: 55)
                .accessibilityLabel(title)
            Stepper("Seconds", value: duckingValue(keyPath), in: 0...10, step: 0.1)
                .labelsHidden()
            Text("s")
        }
    }

    @ViewBuilder
    private var inputSettingsRows: some View {
        Picker("Microphone Mode", selection: inputRouteSelection) {
            Text("Selected Microphone").tag(InputRoute.singleMicrophone)
            Text("Priority Order").tag(InputRoute.priorityOrder)
        }
        .pickerStyle(.menu)

        if !usesPriorityOrder {
            Picker("Microphone", selection: microphoneSourceSelection) {
                Text(systemDefaultSourceTitle).tag(MicrophoneSourceSelection.systemDefault)

                ForEach(audioDeviceManager.availableDevices, id: \.uid) { device in
                    Text(device.name).tag(MicrophoneSourceSelection.device(device.uid))
                }
            }
            .pickerStyle(.menu)

            if let deviceID = audioDeviceManager.resolveCurrentRecordingDevice().deviceID {
                AudioInputChannelsView(deviceID: deviceID)
            }
        }

        Button {
            refreshMicrophones()
        } label: {
            Label {
                Text("Refresh Microphones")
            } icon: {
                Image(systemName: "arrow.clockwise")
                    .rotationEffect(.degrees(refreshIconRotation))
            }
        }
        .buttonStyle(.borderless)
        .help("Refresh Microphones")
    }

    @ViewBuilder
    private var priorityOrderRows: some View {
        if prioritizedDevicesInDisplayOrder.isEmpty {
            Text("Add microphones in the order VoiceInk should try them.")
                .foregroundStyle(.secondary)
        } else {
            ForEach(prioritizedDevicesInDisplayOrder) { device in
                priorityDeviceRow(for: device)
            }
        }

        if !availableDevicesNotInPriorityOrder.isEmpty {
            ForEach(availableDevicesNotInPriorityOrder, id: \.uid) { device in
                availablePriorityDeviceRow(for: device)
            }
        }
    }

    private var inputRouteSelection: Binding<InputRoute> {
        Binding(
            get: { usesPriorityOrder ? .priorityOrder : .singleMicrophone },
            set: { route in
                switch route {
                case .singleMicrophone:
                    selectSingleMicrophoneMode()
                case .priorityOrder:
                    selectPriorityOrderMode()
                }
            }
        )
    }

    private var microphoneSourceSelection: Binding<MicrophoneSourceSelection> {
        Binding(
            get: { currentMicrophoneSource },
            set: { selection in
                microphoneSourceBeforePriorityOrder = selection
                selectMicrophoneSource(selection)
            }
        )
    }

    private func availablePriorityDeviceRow(for device: (id: AudioDeviceID, uid: String, name: String)) -> some View {
        Button {
            audioDeviceManager.addPrioritizedDevice(uid: device.uid, name: device.name)
        } label: {
            HStack(spacing: 8) {
                Label(device.name, systemImage: "plus.circle")
                    .lineLimit(1)

                Spacer()

                Text("Add")
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func priorityDeviceRow(for prioritizedDevice: PrioritizedDevice) -> some View {
        let device = audioDeviceManager.availableDevices.first { $0.uid == prioritizedDevice.id }
        let isAvailable = device != nil
        let isActive = device.map { audioDeviceManager.getCurrentDevice() == $0.id } ?? false

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("\(prioritizedDevice.priority + 1)")
                    .font(.body.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 22, alignment: .leading)

                VStack(alignment: .leading, spacing: 2) {
                    Text(prioritizedDevice.name)
                        .foregroundStyle(isAvailable ? .primary : .secondary)
                        .lineLimit(1)

                    if !isAvailable {
                        Text("Unavailable")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                if isActive {
                    Label("Active", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .labelStyle(.titleAndIcon)
                }

                HStack(spacing: 4) {
                    Button {
                        movePrioritizedDeviceUp(prioritizedDevice)
                    } label: {
                        Image(systemName: "chevron.up")
                    }
                    .disabled(prioritizedDevice.id == prioritizedDevicesInDisplayOrder.first?.id)
                    .help("Move up")

                    Button {
                        movePrioritizedDeviceDown(prioritizedDevice)
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .disabled(prioritizedDevice.id == prioritizedDevicesInDisplayOrder.last?.id)
                    .help("Move down")

                    Button {
                        audioDeviceManager.removePrioritizedDevice(id: prioritizedDevice.id)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .help("Remove")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }

            if let device {
                AudioInputChannelsView(deviceID: device.id)
            }
        }
    }

    private var currentMicrophoneSource: MicrophoneSourceSelection {
        switch audioDeviceManager.inputMode {
        case .systemDefault:
            return .systemDefault
        case .custom:
            if let selectedDeviceUID {
                return .device(selectedDeviceUID)
            }
            return .systemDefault
        case .prioritized:
            return microphoneSourceBeforePriorityOrder
        }
    }

    private func selectMicrophoneSource(_ selection: MicrophoneSourceSelection) {
        switch selection {
        case .systemDefault:
            audioDeviceManager.selectInputMode(.systemDefault)
        case .device(let uid):
            guard let device = audioDeviceManager.availableDevices.first(where: { $0.uid == uid }) else {
                audioDeviceManager.selectInputMode(.systemDefault)
                return
            }
            audioDeviceManager.selectDeviceAndSwitchToCustomMode(id: device.id)
        }
    }

    private func selectSingleMicrophoneMode() {
        selectMicrophoneSource(microphoneSourceBeforePriorityOrder)
    }

    private func selectPriorityOrderMode() {
        if !usesPriorityOrder {
            microphoneSourceBeforePriorityOrder = currentMicrophoneSource
        }
        audioDeviceManager.selectInputMode(.prioritized)
    }

    private var selectedDeviceUID: String? {
        guard let selectedDeviceID = audioDeviceManager.selectedDeviceID else { return nil }
        return audioDeviceManager.availableDevices.first { $0.id == selectedDeviceID }?.uid
    }

    private var systemDefaultSourceTitle: String {
        guard let name = audioDeviceManager.getSystemDefaultDeviceName() else {
            return String(localized: "System Default")
        }
        return String(format: String(localized: "System Default (%@)"), name)
    }

    private func refreshMicrophones() {
        withAnimation(.easeInOut(duration: 0.35)) {
            refreshIconRotation += 360
        }
        audioDeviceManager.loadAvailableDevices()
    }

    private var usesPriorityOrder: Bool {
        audioDeviceManager.inputMode == .prioritized
    }

    private var prioritizedDevicesInDisplayOrder: [PrioritizedDevice] {
        audioDeviceManager.prioritizedDevices.sorted { $0.priority < $1.priority }
    }

    private var availableDevicesNotInPriorityOrder: [(id: AudioDeviceID, uid: String, name: String)] {
        audioDeviceManager.availableDevices.filter { device in
            !audioDeviceManager.prioritizedDevices.contains { $0.id == device.uid }
        }
    }

    private var resumeDelayMenu: some View {
        Picker("Resume Delay", selection: $mediaController.audioResumptionDelay) {
            Text("0s").tag(0.0)
            Text("1s").tag(1.0)
            Text("2s").tag(2.0)
            Text("3s").tag(3.0)
            Text("4s").tag(4.0)
            Text("5s").tag(5.0)
        }
        .pickerStyle(.menu)
        .labelsHidden()
    }

    private var canEditResumeDelay: Bool {
        duckingSettings.configuration.mode == .mute || playbackController.isPauseMediaEnabled
    }

    private func movePrioritizedDeviceUp(_ device: PrioritizedDevice) {
        var devices = prioritizedDevicesInDisplayOrder
        guard let currentIndex = devices.firstIndex(where: { $0.id == device.id }),
            currentIndex > 0
        else { return }

        devices.swapAt(currentIndex, currentIndex - 1)
        updatePriorities(devices)
    }

    private func movePrioritizedDeviceDown(_ device: PrioritizedDevice) {
        var devices = prioritizedDevicesInDisplayOrder
        guard let currentIndex = devices.firstIndex(where: { $0.id == device.id }),
            currentIndex < devices.count - 1
        else { return }

        devices.swapAt(currentIndex, currentIndex + 1)
        updatePriorities(devices)
    }

    private func updatePriorities(_ devices: [PrioritizedDevice]) {
        let updatedDevices = devices.enumerated().map { index, device in
            PrioritizedDevice(id: device.id, name: device.name, priority: index, modelUID: device.modelUID)
        }
        audioDeviceManager.updatePriorities(devices: updatedDevices)
    }
}

private enum MicrophoneSourceSelection: Hashable {
    case systemDefault
    case device(String)
}

private enum InputRoute: Hashable {
    case singleMicrophone
    case priorityOrder
}
