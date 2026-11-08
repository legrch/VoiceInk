import AppKit
import Darwin

@MainActor
final class DevSwitchCoordinator {
    private var gate = DevSwitchGate()
    private var requesterPID: pid_t?
    private let canQuit: @MainActor () -> Bool
    private var observer: NSObjectProtocol?
    private var timer: Timer?
    private var requesterAlive: Bool {
        guard let requesterPID else { return false }
        return Darwin.kill(requesterPID, 0) == 0
    }
    var terminationAllowed: Bool { gate.nonce == nil || (requesterAlive && canQuit()) }

    init(canQuit: @escaping @MainActor () -> Bool) {
        self.canQuit = canQuit
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.prakashjoshipax.VoiceInk.devSwitch"), object: nil, queue: .main
        ) { [weak self] notification in
            guard let info = notification.userInfo,
                  let pid = info["pid"] as? Int, pid == Int(ProcessInfo.processInfo.processIdentifier),
                  let text = info["nonce"] as? String, let nonce = UUID(uuidString: text),
                  let operation = info["operation"] as? String,
                  let requester = info["requester"] as? Int, requester > 0, requester <= Int(Int32.max) else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                if operation == "cancel" { self.gate.cancel(nonce) }
                else if operation == "quitWhenIdle" { self.requesterPID = pid_t(requester); self.gate.request(nonce) }
            }
        }
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let nonce = self.gate.nonce else { return }
                guard self.requesterAlive else { self.gate.cancel(nonce); return }
                guard self.canQuit() else { return }
                NSApplication.shared.terminate(nil)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
}
