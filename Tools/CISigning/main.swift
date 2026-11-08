import Foundation
import Security
import CryptoKit

// No Keychain operation occurs without the explicit upload command.
guard CommandLine.arguments == [CommandLine.arguments[0], "--upload"] else {
    print("Usage: configure-ci-signing.sh --upload (exports only the existing VoiceInk Local identity to legrch/VoiceInk environment release)")
    exit(0)
}
func fail(_ message: String) -> Never { fputs(message + "\n", stderr); exit(1) }
@discardableResult
func run(_ arguments: [String], input: Data? = nil, capture: Bool = false) -> Data {
    let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["gh"] + arguments
    var environment = ProcessInfo.processInfo.environment
    environment["GH_HOST"] = "github.com"
    environment.removeValue(forKey: "GH_DEBUG")
    process.environment = environment
    let pipe = Pipe(); if input != nil { process.standardInput = pipe }
    let output = Pipe(); if capture { process.standardOutput = output }
    var result = Data()
    do {
        try process.run()
        if let input { try pipe.fileHandleForWriting.write(contentsOf: input); try pipe.fileHandleForWriting.close() }
        if capture { result = output.fileHandleForReading.readDataToEndOfFile() }
        process.waitUntilExit()
    } catch { fail("GitHub secret setup failed. Secret values were not printed.") }
    guard process.terminationStatus == 0 else { fail("GitHub rejected secret setup; inspect the named environment before retrying.") }
    return result
}
// Environment approval is enforced by GitHub before candidate-controlled code gets secrets.
let ownerData = run(["api", "users/legrch"], capture: true)
guard let owner = try? JSONSerialization.jsonObject(with: ownerData) as? [String: Any],
      let ownerID = owner["id"] as? Int else { fail("Cannot establish the repository owner's reviewer identity.") }
let pagesData = run(["api", "--paginate", "--slurp", "repos/legrch/VoiceInk/environments"], capture: true)
guard let pages = try? JSONSerialization.jsonObject(with: pagesData) as? [[String: Any]] else { fail("Cannot inspect existing release protection.") }
let environments = pages.flatMap { $0["environments"] as? [[String: Any]] ?? [] }
if let existing = existingReleaseEnvironment(in: environments) {
    guard protectedReleaseEnvironment(existing, ownerID: ownerID) else {
        fail("Existing release environment is not protected by owner approval. Configure its protection before uploading; existing rules were not replaced.")
    }
} else {
    let protection: [String: Any] = ["reviewers": [["type": "User", "id": ownerID]], "prevent_self_review": false]
    guard let body = try? JSONSerialization.data(withJSONObject: protection) else { fail("Cannot encode release protection.") }
    run(["api", "repos/legrch/VoiceInk/environments/release", "--method", "PUT", "--input", "-"], input: body, capture: true)
}
let protectionData = run(["api", "repos/legrch/VoiceInk/environments/release"], capture: true)
guard let environment = try? JSONSerialization.jsonObject(with: protectionData) as? [String: Any],
      protectedReleaseEnvironment(environment, ownerID: ownerID) else { fail("GitHub did not confirm release protection; no key was exported.") }
let inventory = run(["secret", "list", "--repo", "legrch/VoiceInk", "--env", "release", "--json", "name"], capture: true)
guard let entries = try? JSONSerialization.jsonObject(with: inventory) as? [[String: Any]],
      !entries.contains(where: { ["VOICEINK_P12_BASE64", "VOICEINK_P12_PASSWORD"].contains($0["name"] as? String ?? "") }) else {
    fail("Signing secrets already exist or setup is partial. Inspect the two named entries; this helper never rotates or overwrites them blindly.")
}
let expected = "fbb0182020b4091415f9ee73f17b156010daac2291f3f700a85ba4c5d7dbdb89"
var matches: CFTypeRef?
let query: [CFString: Any] = [kSecClass: kSecClassIdentity, kSecReturnRef: true, kSecMatchLimit: kSecMatchLimitAll]
guard SecItemCopyMatching(query as CFDictionary, &matches) == errSecSuccess,
      let identities = matches as? [SecIdentity] else { fail("No exportable signing identity found.") }
let selected = identities.filter { identity in
    var certificate: SecCertificate?
    guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess, let certificate else { return false }
    let digest = SHA256.hash(data: SecCertificateCopyData(certificate) as Data).map { String(format: "%02x", $0) }.joined()
    return digest == expected
}
guard selected.count == 1 else { fail("Expected exactly one matching VoiceInk signing identity.") }
var random = [UInt8](repeating: 0, count: 32)
guard SecRandomCopyBytes(kSecRandomDefault, random.count, &random) == errSecSuccess else { fail("Secure random generation failed.") }
let password = random.map { String(format: "%02x", $0) }.joined()
var parameters = SecItemImportExportKeyParameters()
parameters.version = UInt32(SEC_KEY_IMPORT_EXPORT_PARAMS_VERSION)
let passphrase = password as CFString
parameters.passphrase = Unmanaged.passUnretained(passphrase as CFTypeRef)
var exported: CFData?
let exportStatus = withExtendedLifetime(passphrase) { SecItemExport(selected[0], .formatPKCS12, SecItemImportExportFlags(), &parameters, &exported) }
guard exportStatus == errSecSuccess,
      let exported else { fail("The selected identity could not be exported. No signing secret was uploaded.") }
run(["secret", "set", "VOICEINK_P12_PASSWORD", "--repo", "legrch/VoiceInk", "--env", "release"], input: Data(password.utf8))
run(["secret", "set", "VOICEINK_P12_BASE64", "--repo", "legrch/VoiceInk", "--env", "release"], input: Data((exported as Data).base64EncodedString().utf8))
print("Configured the two signing secrets in legrch/VoiceInk environment release. Key material stayed in memory and was never written to the checkout or printed.")
