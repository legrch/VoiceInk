import Foundation

final class MemoryDefaults: UserDefaults {
    var values: [String: Any] = [:]
    override func object(forKey defaultName: String) -> Any? { values[defaultName] }
    override func data(forKey defaultName: String) -> Data? { values[defaultName] as? Data }
    override func bool(forKey defaultName: String) -> Bool { values[defaultName] as? Bool ?? false }
    override func set(_ value: Any?, forKey defaultName: String) { values[defaultName] = value }
}

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
}

@MainActor
func run() {
    let defaults = MemoryDefaults(suiteName: "voiceink-test-memory-only")!
    defaults.values["isSystemMuteEnabled"] = true
    let initial = AudioDuckingSettings(defaults: defaults)
    check(initial.configuration.mode == .mute && !initial.invalidStoredConfiguration, "legacy migration")
    let bad = Data("{invalid".utf8)
    defaults.values[AudioDuckingSettings.storageKey] = bad
    let corrupt = AudioDuckingSettings(defaults: defaults)
    check(corrupt.configuration.mode == .unchanged && corrupt.invalidStoredConfiguration, "corrupt payload selects unchanged")
    check(defaults.values[AudioDuckingSettings.storageKey] as? Data == bad, "corrupt bytes preserved")
    defaults.values[AudioDuckingSettings.storageKey] = "wrong type"
    let wrongType = AudioDuckingSettings(defaults: defaults)
    check(wrongType.configuration.mode == .unchanged && wrongType.invalidStoredConfiguration, "wrong type selects unchanged")
    var valid = AudioDuckingConfiguration(mode: .duck)
    valid.retainedPercent = 35
    check(wrongType.set(valid), "valid configuration saved")
    let reloaded = AudioDuckingSettings(defaults: defaults)
    check(reloaded.configuration == valid && !reloaded.invalidStoredConfiguration, "saved configuration reloads")
    var older = valid
    older.fadeDownSeconds = 2
    older.fadeUpSeconds = 0.5
    defaults.values[AudioDuckingSettings.storageKey] = try! JSONEncoder().encode(older)
    let migrated = AudioDuckingSettings(defaults: defaults)
    check(migrated.configuration.fadeDownSeconds == 2 && migrated.configuration.fadeUpSeconds == 2,
          "old separate durations migrate to a single fade duration")
    let persisted = try! JSONDecoder().decode(AudioDuckingConfiguration.self, from: defaults.data(forKey: AudioDuckingSettings.storageKey)!)
    check(persisted.fadeUpSeconds == 2, "unified duration persists across restart")
    let legacyJSON = Data("""
    {"version":1,"mode":"duck","retainedPercent":20,"fadeDownSeconds":1,"fadeUpSeconds":1,"restoreDelaySeconds":0}
    """.utf8)
    var perDevice = try! JSONDecoder().decode(AudioDuckingConfiguration.self, from: legacyJSON)
    check(perDevice.retainedPercent(for: "speakers") == 20, "older settings keep the default level")
    perDevice.setRetainedPercent(25, for: "speakers")
    perDevice.setRetainedPercent(55, for: "headphones")
    check(perDevice.retainedPercent(for: "speakers") == 25 && perDevice.retainedPercent(for: "headphones") == 55 && perDevice.retainedPercent(for: "unknown") == 20,
          "per-device levels remain independent with a default for new outputs")
    check(migrated.set(perDevice), "per-device settings save")
    let devicesReloaded = AudioDuckingSettings(defaults: defaults)
    check(devicesReloaded.configuration.retainedPercent(for: "headphones") == 55, "per-device settings survive restart")
    var invalid = valid
    invalid.fadeUpSeconds = .infinity
    check(!reloaded.set(invalid) && reloaded.configuration == valid, "invalid update leaves configuration intact")
    print("AudioDucking settings migration and corruption checks passed")
}
MainActor.assumeIsolated { run() }
