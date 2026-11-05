import Foundation

/// Reads recovery evidence and named outputs without acquiring the journal lock
/// or changing audio. The report includes device identifiers.
@main struct InspectRecoveryReadOnly {
    static func main() throws {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.prakashjoshipax.VoiceInk/PersonalAudioDucking", isDirectory: true)
        guard FileManager.default.fileExists(atPath: dir.path) else { print("recovery journal: absent"); return }
        let entries = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent == "recovery-v1.json" || (($0.lastPathComponent.hasPrefix("acknowledged-") || $0.lastPathComponent.hasPrefix("held-") || $0.lastPathComponent.hasPrefix("accepted-")) && $0.pathExtension == "json") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !entries.isEmpty else { print("recovery journal: absent"); return }
        let output = AudioDuckingCoreAudio()
        for file in entries {
            if file.lastPathComponent.hasPrefix("accepted-") {
                guard let bytes = try? Data(contentsOf: file), bytes.count <= 65_536,
                      let receipt = try? JSONDecoder().decode(AudioDuckingRecoveryJournal.Acknowledgment.self, from: bytes), receipt.record.isValid else {
                    print("acknowledgment evidence: invalid"); continue
                }
                let stillBlocked = entries.contains { item in
                    guard item.lastPathComponent == "recovery-v1.json" || item.lastPathComponent.hasPrefix("held-") || item.lastPathComponent.hasPrefix("acknowledged-"),
                          let data = try? Data(contentsOf: item),
                          let record = try? JSONDecoder().decode(AudioDuckingRecoveryRecord.self, from: data) else { return false }
                    return record.cycleID == receipt.record.cycleID
                }
                let state = stillBlocked ? "acknowledgment prepared; intent remains blocked" : "owner acknowledged"
                print("evidence: \(state), reason: \(receipt.reason), time: \(receipt.acknowledgedAt)")
                print("device UID: \(receipt.observedUID); observed values: \(receipt.observedValues); mute: \(String(describing: receipt.observedMute))")
                print("original phase: \(receipt.record.phase.rawValue); baseline: \(receipt.record.baseline); confirmed: \(receipt.record.confirmed); target: \(String(describing: receipt.record.intended))")
                continue
            }
            guard let bytes = try? Data(contentsOf: file), bytes.count <= 65_536,
                  let record = try? JSONDecoder().decode(AudioDuckingRecoveryRecord.self, from: bytes), record.isValid else {
                print("recovery evidence: invalid"); continue
            }
            print("evidence: \(file.lastPathComponent == "recovery-v1.json" ? "active" : (file.lastPathComponent.hasPrefix("held-") ? "held, not acknowledged, device blocked" : "acknowledged, device still blocked"))")
            print("phase: \(record.phase.rawValue); device UID: \(record.deviceUID)")
            print("control: \(record.control.rawValue); elements: \(record.elements); stereo channels: \(record.stereoChannels)")
            print("baseline: \(record.baseline); confirmed: \(record.confirmed); target: \(String(describing: record.intended))")
            print("recorded mute: \(String(describing: record.muted))")
            guard let device = output.device(forUID: record.deviceUID) else {
                print("observation: device missing; pending effects remain uncertain"); continue
            }
            let snapshot = output.readNamed(deviceID: device)
            print("observation: \(record.observe(snapshot).rawValue)")
            print("current values: \(String(describing: snapshot?.values)); mute: \(String(describing: snapshot?.muted))")
        }
        print("A matching readback does not establish ownership or cancel an in-flight write.")
    }
}
