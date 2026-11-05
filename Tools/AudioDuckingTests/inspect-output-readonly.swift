import Foundation
import CoreAudio

@main struct InspectOutputReadOnly {
    static func main() {
        let output = AudioDuckingCoreAudio()
        guard let snapshot = output.readDefault(), let baseline = snapshot.values.first,
              let element = snapshot.elements.first else {
            print("output unavailable")
            return
        }
        print("baseline=\(baseline)")
        print("control=\(snapshot.control.rawValue)")
        for fraction: Float in [1, 0.9, 0.75, 0.5, 0.2, 0.1] {
            let requested = baseline * fraction
            if snapshot.control == .physicalMain {
                var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalarToDecibels, mScope: kAudioDevicePropertyScopeOutput, mElement: element)
                var intermediate = requested
                var bytes = UInt32(MemoryLayout<Float>.size)
                let conversionStatus = AudioObjectGetPropertyData(snapshot.deviceID, &address, 0, nil, &bytes, &intermediate)
                print("scalar_to_db_status=\(conversionStatus) db=\(intermediate)")
            }
            if let actual = output.canonicalTarget(deviceID: snapshot.deviceID, element: element, value: requested) {
                print("requested=\(requested) canonical=\(actual) exact=\(requested == actual)")
                guard requested == actual else {
                    print("FAIL: scalar target was changed before the hardware write")
                    exit(1)
                }
            } else {
                print("conversion unavailable")
                exit(1)
            }
        }
    }
}
