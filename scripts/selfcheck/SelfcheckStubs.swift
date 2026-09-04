import Foundation

// MonitoredAccount references a few app types that live in UI-adjacent files.
// The self-check only needs them to exist with the right shape.

enum CodexTokenRefresher {
    enum WriteBack: Sendable {
        case codexAuthJSON
        case codexAuthJSONAt(path: String)
        case importedAccount(id: String)
    }
}

@MainActor
func tr(_ english: String, _ chinese: String) -> String { english }
