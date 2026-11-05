import Foundation

/// Release identity is generated from release/plus.json into the main app's
/// Info.plist. XPC helpers retain their own upstream version/build settings.
struct PlusReleaseMetadata: Equatable {
    let upstreamVersion: String
    let upstreamCommit: String
    let revision: String
    let build: String
    let tag: String
    static let product = "VoiceInk Plus"
    static let latestReleaseURL = URL(string: "https://github.com/legrch/VoiceInk/releases/latest")!
    static let repositoryURL = URL(string: "https://github.com/legrch/VoiceInk")!
    static var current: Self? { Self(info: Bundle.main.infoDictionary ?? [:]) }

    init?(info: [String: Any]) {
        guard info["VoiceInkPlusProduct"] as? String == Self.product,
              let version = info["CFBundleShortVersionString"] as? String,
              let commit = info["VoiceInkUpstreamCommit"] as? String,
              let revision = info["VoiceInkPlusRevision"] as? String,
              let build = info["CFBundleVersion"] as? String,
              let tag = info["VoiceInkPlusTag"] as? String,
              version.range(of: #"^[0-9]+(?:\.[0-9]+){1,2}$"#, options: .regularExpression) != nil,
              commit.range(of: #"^[a-f0-9]{40}$"#, options: .regularExpression) != nil,
              Int(revision).map({ $0 > 0 }) == true,
              Int(build).map({ $0 > 225 }) == true,
              tag == "plus-v\(version)-r\(revision)" else { return nil }
        upstreamVersion = version
        upstreamCommit = commit
        self.revision = revision
        self.build = build
        self.tag = tag
    }
    var displayVersion: String { "\(upstreamVersion) · r\(revision)" }
}
