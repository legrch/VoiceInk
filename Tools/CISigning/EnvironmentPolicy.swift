import Foundation

func protectedReleaseEnvironment(_ environment: [String: Any], ownerID: Int) -> Bool {
    guard let rules = environment["protection_rules"] as? [[String: Any]] else { return false }
    return rules.contains { rule in
        guard rule["type"] as? String == "required_reviewers",
              let reviewers = rule["reviewers"] as? [[String: Any]], reviewers.count == 1,
              reviewers[0]["type"] as? String == "User",
              let reviewer = reviewers[0]["reviewer"] as? [String: Any] else { return false }
        return reviewer["id"] as? Int == ownerID
    }
}
