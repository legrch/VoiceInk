import Foundation
func check(_ value: @autoclosure () -> Bool, _ message: String) {
    guard value() else { fatalError(message) }
}
let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
let info = try PropertyListSerialization.propertyList(from: data, format: nil) as! [String: Any]
let release = PlusReleaseMetadata(info: info)!
check(release.displayVersion == "2.25 · r1" && release.build == "1001", "Show upstream version and fork revision separately")
check(release.tag == "plus-v2.25-r1", "Show installed immutable release tag")
for key in ["VoiceInkPlusProduct", "VoiceInkUpstreamCommit", "CFBundleVersion", "VoiceInkPlusTag"] {
    var invalid = info; invalid[key] = "invalid"
    check(PlusReleaseMetadata(info: invalid) == nil, "Reject inconsistent metadata: \(key)")
}
var patch = info
patch["CFBundleShortVersionString"] = "2.25.1"
patch["VoiceInkPlusTag"] = "plus-v2.25.1-r1"
check(PlusReleaseMetadata(info: patch)?.upstreamVersion == "2.25.1", "Retain full upstream patch version")
print("Plus release identity, provenance and invalid-metadata checks passed")
