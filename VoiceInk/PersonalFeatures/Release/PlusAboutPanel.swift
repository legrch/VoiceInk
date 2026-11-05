import AppKit

@MainActor
enum PlusAboutPanel {
    static func show() {
        guard let release = PlusReleaseMetadata.current else {
            NSApplication.shared.orderFrontStandardAboutPanel(nil)
            return
        }
        let text = "Independent fork of VoiceInk \(release.upstreamVersion).\nRelease: \(release.tag)\n\nLatest Release · Fork Repository\n\nFor new-release alerts on GitHub, choose\nWatch → Custom → Releases.\nUpdates are installed manually."
        let credits = NSMutableAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.labelColor
        ])
        for (label, url) in [("Latest Release", PlusReleaseMetadata.latestReleaseURL),
                             ("Fork Repository", PlusReleaseMetadata.repositoryURL)] {
            credits.addAttribute(.link, value: url, range: (text as NSString).range(of: label))
        }
        NSApplication.shared.orderFrontStandardAboutPanel(options: [
            .applicationName: PlusReleaseMetadata.product,
            .applicationVersion: release.displayVersion,
            .version: release.build,
            .credits: credits
        ])
    }
}
