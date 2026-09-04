import Foundation

/// Where an account was discovered. The key is stable across launches so
/// caches, history and settings can be keyed by `AccountID`.
nonisolated enum AccountSource: Hashable, Codable, Sendable {
    case defaultLogin
    case importedCodex(id: String)
    case ccpm(profile: String)

    var key: String {
        switch self {
        case .defaultLogin: return "default"
        case .importedCodex(let id): return "imported:\(id)"
        case .ccpm(let profile): return "ccpm:\(profile)"
        }
    }
}

nonisolated struct AccountID: Hashable, Codable, Sendable, CustomStringConvertible {
    let raw: String

    init(raw: String) { self.raw = raw }

    init(provider: Provider, source: AccountSource) {
        raw = "\(provider.rawValue):\(source.key)"
    }

    var description: String { raw }

    init(from decoder: Decoder) throws {
        raw = try decoder.singleValueContainer().decode(String.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(raw)
    }
}

nonisolated enum AccountCredential: Sendable {
    case codexOAuth(CodexAccount, writeBack: CodexTokenRefresher.WriteBack)
    case claudeOAuth(ClaudeAccount, storage: ClaudeCredentialStorage)
    case apiKey(String, baseURL: URL)
    case ollamaCookie(cookieHeader: String?, baseURL: URL)
    case unavailable(reason: String)

    /// Accounts that can never produce a quota snapshot are still listed so
    /// their local usage shows up, but the refresh loop skips them.
    var canFetchQuota: Bool {
        if case .unavailable = self { return false }
        return true
    }
}

nonisolated struct AccountIdentity: Sendable, Equatable {
    var email: String?
    var displayName: String?
    var plan: String?
    var profileName: String?
    var profileDir: String?
    var isDefaultProfile: Bool = false
    /// Stable identity fingerprint (account id or email). When it changes for
    /// the same `AccountID` the cached quota is discarded.
    var fingerprint: String?
}

nonisolated struct MonitoredAccount: Identifiable, Sendable {
    let id: AccountID
    let provider: Provider
    let source: AccountSource
    var identity: AccountIdentity
    var credential: AccountCredential
    /// JSONL roots scanned for local token usage. Empty for imported accounts.
    var usageRoots: [URL]
    /// When set, quota state is read from that account instead of fetched.
    var mirrorsAccount: AccountID?

    var descriptor: ProviderDescriptor { provider.descriptor }

    var isDefaultLogin: Bool {
        if case .defaultLogin = source { return true }
        return false
    }

    /// Short human label used in risk banners, timeline titles and compact rows.
    @MainActor
    func shortTitle(index: Int, privacy: Bool) -> String {
        if privacy {
            switch source {
            case .defaultLogin: return tr("Default", "默认")
            case .importedCodex, .ccpm: return tr("Account \(index + 1)", "账号 \(index + 1)")
            }
        }
        switch source {
        case .defaultLogin:
            if let email = identity.email, !email.isEmpty { return emailUsername(email) }
            return tr("Default", "默认")
        case .importedCodex:
            if let name = identity.displayName, !name.isEmpty { return name }
            if let email = identity.email, !email.isEmpty { return emailUsername(email) }
            return identity.profileName ?? id.raw
        case .ccpm(let profile):
            if let name = identity.displayName, !name.isEmpty { return name }
            return profile
        }
    }

    private func emailUsername(_ email: String) -> String {
        email.components(separatedBy: "@").first ?? email
    }
}
