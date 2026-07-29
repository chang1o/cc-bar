import Foundation

enum CredentialSource: String, Sendable {
    case file
    case keychain
}

enum ClaudeCredentialStorage: Sendable, Equatable, Hashable {
    case file(path: String)
    case keychain(service: String)

    var cacheKey: String {
        switch self {
        case .file(let path): return "file:\(path)"
        case .keychain(let service): return "keychain:\(service)"
        }
    }
}

struct CodexAccount: Sendable, Equatable {
    var email: String?
    var planType: String?
    var accountId: String?
    var chatgptUserId: String?
    var lastRefresh: Date?
    var expiredGuess: Bool
    var rawClaimKeys: [String]
    /// 仅内存使用，不打印 / 不持久化到 UserDefaults
    var accessToken: String?
    var refreshToken: String?
    var idToken: String?
}

struct ClaudeAccount: Sendable, Equatable {
    var source: CredentialSource
    var email: String?
    var subscriptionType: String?
    var expiresAt: Date?
    var expiredGuess: Bool
    /// 仅内存使用，不打印 / 不持久化到 UserDefaults
    var accessToken: String?
    var refreshToken: String?
}

enum CredentialError: Error, CustomStringConvertible {
    case fileNotFound(String)
    case invalidJSON(String)
    case keychainUnavailable(String)
    case decodeFailed(String)

    var description: String {
        switch self {
        case .fileNotFound(let p): return "file not found: \(p)"
        case .invalidJSON(let p): return "invalid JSON at: \(p)"
        case .keychainUnavailable(let m): return "keychain unavailable: \(m)"
        case .decodeFailed(let m): return "decode failed: \(m)"
        }
    }
}
