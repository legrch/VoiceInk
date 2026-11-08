import Foundation
func check(_ value: Bool, _ message: String) { precondition(value, message) }
var gate = DevSwitchGate()
check(!gate.mayQuit(recordingIdle: true, pipelineIdle: true, outputIdle: true, importsIdle: true), "No unsolicited quit")
let first = UUID(), second = UUID()
gate.request(first)
for busy in 0..<4 {
    let flags = (0..<4).map { $0 != busy }
    check(!gate.mayQuit(recordingIdle: flags[0], pipelineIdle: flags[1], outputIdle: flags[2], importsIdle: flags[3]), "Each work lane prevents quit")
}
check(gate.mayQuit(recordingIdle: true, pipelineIdle: true, outputIdle: true, importsIdle: true), "Explicit request quits only at idle")
gate.request(second); gate.cancel(first)
check(gate.nonce == second, "Old cancellation cannot cancel a new request")
gate.cancel(second)
check(!gate.mayQuit(recordingIdle: true, pipelineIdle: true, outputIdle: true, importsIdle: true), "Cancellation prevents late quit")
print("Dev quit gate and stale cancellation checks passed")
