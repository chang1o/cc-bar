import Foundation

/// A quota-bearing account discovered from a ccpm profile. Layered on top of the primary
/// (machine-level) account of each `QuotaApp`; Kimi / GLM exist only this way.
nonisolated struct CCPMAccount: Identifiable, Sendable, Hashable {
    enum Availability: Sendable, Hashable {
        case ready
        case unavailable(reason: String)
    }

    /// Secrets used by the refresh path. Excluded from Equatable / Hashable on purpose:
    /// token rotation must not look like an account change to the UI.
    enum Credential: Sendable {
        case codexOAuth(CodexAccount)
        case claudeOAuth(ClaudeAccount)
        case apiKey(String, baseURL: URL)
        case ollamaAPIKey(String)
        case none
    }

    let profile: CCPMProfile
    let app: QuotaApp
    /// Email, host or other identity hint shown under the account label.
    let detail: String?
    /// Plan name known from local credentials; the snapshot's planType wins when present.
    let planType: String?
    let availability: Availability
    /// Same identity as the app's primary account: reuse the primary quota state.
    let mirrorsPrimary: Bool
    let credential: Credential

    var id: String { "\(app.rawValue):ccpm:\(profile.name)" }
    var label: String { profile.label }
    var isReady: Bool { availability == .ready }

    var unavailableReason: String? {
        if case .unavailable(let reason) = availability { return reason }
        return nil
    }

    static func == (lhs: CCPMAccount, rhs: CCPMAccount) -> Bool {
        lhs.profile == rhs.profile
            && lhs.app == rhs.app
            && lhs.detail == rhs.detail
            && lhs.planType == rhs.planType
            && lhs.availability == rhs.availability
            && lhs.mirrorsPrimary == rhs.mirrorsPrimary
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

nonisolated enum CCPMAccountCatalog {
    private static let noQuotaEndpoint = "API key profile: no quota endpoint"

    /// Builds accounts from `~/.ccpm/config.json` plus the matching credential stores.
    /// Runs off the main actor; touches the Keychain through the `security` CLI.
    nonisolated static func discover(primaryCodexAccountId: String?, primaryClaudeEmail: String?) -> [CCPMAccount] {
        CCPMProfileCatalog.load().compactMap { profile in
            switch profile.provider {
            case "codex":
                return codex(profile, primaryAccountId: nonEmpty(primaryCodexAccountId))
            case "anthropic":
                return claude(profile, primaryEmail: nonEmpty(primaryClaudeEmail)?.lowercased())
            case "kimi":
                return apiKey(profile, app: .kimi, defaultBaseURL: KimiQuotaClient.defaultBaseURL)
            case "glm":
                return apiKey(profile, app: .glm, defaultBaseURL: GLMQuotaClient.defaultBaseURL)
            case "ollama":
                return ollama(profile)
            default:
                print("[ccpm] ignoring profile \(profile.name): unknown provider \(profile.provider)")
                return nil
            }
        }
    }

    private static func codex(_ profile: CCPMProfile, primaryAccountId: String?) -> CCPMAccount {
        guard !profile.usesAPIKey else {
            return CCPMAccount(profile: profile, app: .codex, detail: nil, planType: nil,
                               availability: .unavailable(reason: noQuotaEndpoint), mirrorsPrimary: false, credential: .none)
        }
        do {
            let account = try CodexAuth.load(from: profile.authFileURL)
            let mirrors = zipNonEmpty(account.accountId, primaryAccountId).map { $0 == $1 } ?? false
            return CCPMAccount(
                profile: profile, app: .codex, detail: account.email, planType: account.planType,
                availability: .ready, mirrorsPrimary: mirrors, credential: .codexOAuth(account)
            )
        } catch {
            return CCPMAccount(profile: profile, app: .codex, detail: nil, planType: nil,
                               availability: .unavailable(reason: "\(error)"), mirrorsPrimary: false, credential: .none)
        }
    }

    private static func claude(_ profile: CCPMProfile, primaryEmail: String?) -> CCPMAccount {
        let identity = CCPMClaudeProfileStore.readIdentity(profile: profile)
        let plan = identity.organizationType?.replacingOccurrences(of: "_", with: " ").capitalized
        guard !profile.usesAPIKey else {
            return CCPMAccount(profile: profile, app: .claude, detail: identity.email, planType: plan,
                               availability: .unavailable(reason: noQuotaEndpoint), mirrorsPrimary: false, credential: .none)
        }
        do {
            let account = try CCPMClaudeProfileStore.loadOAuthAccount(profile: profile, identity: identity)
            let email = account.email ?? identity.email
            let mirrors = zipNonEmpty(email?.lowercased(), primaryEmail).map { $0 == $1 } ?? false
            return CCPMAccount(
                profile: profile, app: .claude, detail: email,
                planType: account.subscriptionType?.capitalized ?? plan,
                availability: .ready, mirrorsPrimary: mirrors, credential: .claudeOAuth(account)
            )
        } catch {
            return CCPMAccount(profile: profile, app: .claude, detail: identity.email, planType: plan,
                               availability: .unavailable(reason: "\(error)"), mirrorsPrimary: false, credential: .none)
        }
    }

    private static func apiKey(_ profile: CCPMProfile, app: QuotaApp, defaultBaseURL: URL) -> CCPMAccount {
        let baseURL = profile.resolvedBaseURL ?? defaultBaseURL
        guard let key = CCPMKeystore.credential(for: profile) else {
            return CCPMAccount(profile: profile, app: app, detail: baseURL.host, planType: nil,
                               availability: .unavailable(reason: "No API key in ccpm keystore"),
                               mirrorsPrimary: false, credential: .none)
        }
        return CCPMAccount(profile: profile, app: app, detail: baseURL.host, planType: nil,
                           availability: .ready, mirrorsPrimary: false, credential: .apiKey(key, baseURL: baseURL))
    }

    /// ccpm ollama profiles carry an ollama.com API key (Bearer); the primary account uses
    /// the local signing key instead and is discovered by `AppState.loadOllama`.
    private static func ollama(_ profile: CCPMProfile) -> CCPMAccount {
        guard let key = CCPMKeystore.credential(for: profile) else {
            return CCPMAccount(profile: profile, app: .ollama, detail: "ollama.com", planType: nil,
                               availability: .unavailable(reason: "No API key in ccpm keystore"),
                               mirrorsPrimary: false, credential: .none)
        }
        return CCPMAccount(profile: profile, app: .ollama, detail: "ollama.com", planType: nil,
                           availability: .ready, mirrorsPrimary: false, credential: .ollamaAPIKey(key))
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    private static func zipNonEmpty(_ lhs: String?, _ rhs: String?) -> (String, String)? {
        guard let l = nonEmpty(lhs), let r = nonEmpty(rhs) else { return nil }
        return (l, r)
    }
}
