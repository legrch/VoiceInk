import Foundation
let ownerID = 123
let valid: [String: Any] = ["protection_rules": [["type": "required_reviewers", "reviewers": [["type": "User", "reviewer": ["id": ownerID]]]]]]
precondition(protectedReleaseEnvironment(valid, ownerID: ownerID))
precondition(!protectedReleaseEnvironment([:], ownerID: ownerID))
precondition(!protectedReleaseEnvironment(["protection_rules": []], ownerID: ownerID))
precondition(!protectedReleaseEnvironment(valid, ownerID: ownerID + 1))
let others: [String: Any] = ["protection_rules": [["type": "required_reviewers", "reviewers": [["type": "User", "reviewer": ["id": ownerID]], ["type": "User", "reviewer": ["id": 999]]]]]]
precondition(!protectedReleaseEnvironment(others, ownerID: ownerID))
print("Signing environment rejects missing, wrong and broadened approval policies")
