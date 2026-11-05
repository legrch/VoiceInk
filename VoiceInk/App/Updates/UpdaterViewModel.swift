import Combine
import Foundation
import SwiftUI

/// This personal source build is updated manually so an upstream binary cannot
/// replace the customized application. Existing update preferences are untouched.
@MainActor
final class UpdaterViewModel: ObservableObject {
    struct AvailableUpdate: Equatable {
        let versionIdentifier: String
        let displayVersion: String
    }

    let canCheckForUpdates = false
    @Published private(set) var availableUpdate: AvailableUpdate?

    func checkForUpdatesIfDue() {}
    func checkForUpdates() {}
}

struct CheckForUpdatesView: View {
    @ObservedObject var updaterViewModel: UpdaterViewModel

    var body: some View {
        Button("Updates Managed Manually", action: updaterViewModel.checkForUpdates)
            .disabled(true)
    }
}
