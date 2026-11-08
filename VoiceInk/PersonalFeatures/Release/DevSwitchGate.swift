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
    private var restorations = Set<UUID>()
    private var historyWork = Set<ObjectIdentifier>()
    var isIdle: Bool { restorations.isEmpty && historyWork.isEmpty }
    func beginRestoration() -> UUID { let id = UUID(); restorations.insert(id); return id }
    func endRestoration(_ id: UUID) { restorations.remove(id) }
    func setHistoryBusy(_ owner: ObjectIdentifier, _ busy: Bool) {
        if busy { historyWork.insert(owner) } else { historyWork.remove(owner) }
    }
}
