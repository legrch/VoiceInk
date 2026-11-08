import Foundation
let args = CommandLine.arguments
 guard args.count == 5, let pid = Int(args[1]), pid > 0,
       UUID(uuidString: args[2]) != nil, ["quitWhenIdle", "cancel"].contains(args[3]),
       let requester = Int(args[4]), requester > 0, requester <= Int(Int32.max) else { exit(2) }
DistributedNotificationCenter.default().postNotificationName(
    Notification.Name("com.prakashjoshipax.VoiceInk.devSwitch"), object: nil,
    userInfo: ["pid": pid, "nonce": args[2], "operation": args[3], "requester": requester], deliverImmediately: true)
