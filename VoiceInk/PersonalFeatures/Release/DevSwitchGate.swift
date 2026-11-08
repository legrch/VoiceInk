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
    /// Acquire before scheduling; retain ownership through every awaited cleanup.
    @discardableResult
    func track(afterNanoseconds delay: UInt64 = 0, _ operation: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let token = beginWork()
        return Task { @MainActor in
            defer { self.endWork(token) }
            if delay > 0 {
                do { try await Task.sleep(nanoseconds: delay) }
                catch { return }
            }
            await operation()
        }
    }
    func beginWork() -> UUID { let id = UUID(); pendingWork.insert(id); return id }
    func endWork(_ id: UUID) { pendingWork.remove(id) }
}
