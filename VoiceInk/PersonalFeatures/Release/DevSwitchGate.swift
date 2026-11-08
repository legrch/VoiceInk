import Foundation

/// An explicit request may terminate only at an app-observed idle boundary.
struct DevSwitchGate {
    private(set) var nonce: UUID?
    mutating func request(_ nonce: UUID) { self.nonce = nonce }
    mutating func cancel(_ nonce: UUID) { if self.nonce == nonce { self.nonce = nil } }
    func mayQuit(recordingIdle: Bool, pipelineIdle: Bool, outputIdle: Bool, importsIdle: Bool) -> Bool {
        nonce != nil && recordingIdle && pipelineIdle && outputIdle && importsIdle
    }
}

@MainActor
final class DevSwitchActivity {
    static let shared = DevSwitchActivity()
    private var pendingWork = Set<UUID>()
    var isIdle: Bool { pendingWork.isEmpty }
    func beginWork() -> UUID { let id = UUID(); pendingWork.insert(id); return id }
    func endWork(_ id: UUID) { pendingWork.remove(id) }
}
