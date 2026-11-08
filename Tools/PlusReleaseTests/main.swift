import Foundation
func check(_ value: @autoclosure () -> Bool, _ message: String) {
    guard value() else { fatalError(message) }
}
let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
let info = try PropertyListSerialization.propertyList(from: data, format: nil) as! [String: Any]
let release = PlusReleaseMetadata(info: info)!
let manifestData = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
let manifest = try JSONSerialization.jsonObject(with: manifestData) as! [String: Any]
let version = manifest["upstream_version"] as! String
let revision = String(manifest["revision"] as! Int)
let build = String(manifest["build"] as! Int)
check(release.displayVersion == "\(version) · r\(revision)" && release.build == build, "Show upstream version and fork revision separately")
check(release.tag == "plus-v\(version)-r\(revision)", "Show installed immutable release tag")
for key in ["VoiceInkPlusProduct", "VoiceInkUpstreamCommit", "CFBundleVersion", "VoiceInkPlusTag"] {
    var invalid = info; invalid[key] = "invalid"
    check(PlusReleaseMetadata(info: invalid) == nil, "Reject inconsistent metadata: \(key)")
}
var patch = info
patch["CFBundleShortVersionString"] = "2.25.1"
patch["VoiceInkPlusTag"] = "plus-v2.25.1-r\(revision)"
check(PlusReleaseMetadata(info: patch)?.upstreamVersion == "2.25.1", "Retain full upstream patch version")
print("Plus release identity, provenance and invalid-metadata checks passed")

var development = info
development["VoiceInkDevDescription"] = "plus-v2.25-r3-2-gabcdef0"
check(PlusReleaseMetadata(info: development)?.displayVersion.contains("Dev plus-v2.25-r3-2-gabcdef0") == true, "Development provenance is visible")
development["VoiceInkDevDescription"] = "bad\nvalue"
check(PlusReleaseMetadata(info: development) == nil, "Malformed development provenance is rejected")
