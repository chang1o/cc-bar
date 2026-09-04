import Foundation

/// Builds the list of monitored accounts from local credentials, imported
/// Codex accounts and ccpm profiles. Runs off the main actor; never touches UI.
nonisolated enum AccountCatalog {
    struct Discovery: Sendable {
        var accounts: [MonitoredAccount] = []
    }

    nonisolated static func discover(importedAccounts: [ImportedCodexAccount]) -> Discovery {
        var accounts: [MonitoredAccount] = []
        let home = FileManager.default.homeDirectoryForCurrentUser

        // Default Codex login.
        let defaultCodex = defaultCodexAccount(home: home)
        accounts.append(defaultCodex)

        // Default Claude login.
        accounts.append(defaultClaudeAccount(home: home))

        // Imported Codex accounts (only the ones the user wants monitored).
        for imported in importedAccounts where imported.visibleInPopover {
            accounts.append(importedCodexAccount(imported))
        }

        // ccpm profiles.
        let profiles = CCPMProfileCatalog.loadProfiles().sorted(by: profileOrder)
        for profile in profiles {
            if let account = ccpmAccount(profile) {
                accounts.append(account)
            }
        }

        applyCodexMirrors(&accounts, defaultCodex: defaultCodex)

        let order = Dictionary(uniqueKeysWithValues: Provider.allCases.enumerated().map { ($1, $0) })
        accounts.sort { lhs, rhs in
            let l = order[lhs.provider] ?? 0
            let r = order[rhs.provider] ?? 0
            if l != r { return l < r }
            return false
        }
        return Discovery(accounts: accounts)
    }

    // MARK: - Default logins

    private static func defaultCodexAccount(home: URL) -> MonitoredAccount {
        let id = AccountID(provider: .codex, source: .defaultLogin)
        let roots = [
            home.appendingPathComponent(".codex/sessions", isDirectory: true),
            home.appendingPathComponent(".codex/archived_sessions", isDirectory: true)
        ]
        do {
            let account = try CodexAuth.load()
            return MonitoredAccount(
                id: id,
                provider: .codex,
                source: .defaultLogin,
                identity: AccountIdentity(
                    email: account.email,
                    plan: account.planType,
                    fingerprint: nonEmpty(account.accountId) ?? account.email
                ),
                credential: .codexOAuth(account, writeBack: .codexAuthJSON),
                usageRoots: roots
            )
        } catch {
            return MonitoredAccount(
                id: id,
                provider: .codex,
                source: .defaultLogin,
                identity: AccountIdentity(),
                credential: .unavailable(reason: "\(error)"),
                usageRoots: roots
            )
        }
    }

    private static func defaultClaudeAccount(home: URL) -> MonitoredAccount {
        let id = AccountID(provider: .claude, source: .defaultLogin)
        let roots = [home.appendingPathComponent(".claude/projects", isDirectory: true)]
        do {
            let account = try ClaudeAuth.load()
            let storage: ClaudeCredentialStorage
            switch account.source {
            case .file:
                storage = .file(path: home.appendingPathComponent(".claude/.credentials.json").path)
            case .keychain:
                storage = .keychain(service: "Claude Code-credentials")
            }
            return MonitoredAccount(
                id: id,
                provider: .claude,
                source: .defaultLogin,
                identity: AccountIdentity(
                    email: account.email,
                    plan: account.subscriptionType,
                    fingerprint: account.email
                ),
                credential: .claudeOAuth(account, storage: storage),
                usageRoots: roots
            )
        } catch {
            return MonitoredAccount(
                id: id,
                provider: .claude,
                source: .defaultLogin,
                identity: AccountIdentity(),
                credential: .unavailable(reason: "\(error)"),
                usageRoots: roots
            )
        }
    }

    // MARK: - Imported Codex

    private static func importedCodexAccount(_ imported: ImportedCodexAccount) -> MonitoredAccount {
        let id = AccountID(provider: .codex, source: .importedCodex(id: imported.id))
        let identity = AccountIdentity(
            email: imported.email,
            displayName: imported.alias.isEmpty ? nil : imported.alias,
            plan: imported.planType,
            fingerprint: imported.id
        )
        guard let tokens = ImportedCodexStore.loadTokens(accountId: imported.id) else {
            return MonitoredAccount(
                id: id,
                provider: .codex,
                source: .importedCodex(id: imported.id),
                identity: identity,
                credential: .unavailable(reason: "missing tokens in keychain"),
                usageRoots: []
            )
        }
        let account = CodexAccount(
            email: imported.email,
            planType: imported.planType,
            accountId: imported.chatgptAccountId,
            chatgptUserId: importedUserId(imported),
            lastRefresh: nil,
            expiredGuess: false,
            rawClaimKeys: [],
            accessToken: tokens.accessToken,
            refreshToken: tokens.refreshToken,
            idToken: tokens.idToken
        )
        return MonitoredAccount(
            id: id,
            provider: .codex,
            source: .importedCodex(id: imported.id),
            identity: identity,
            credential: .codexOAuth(account, writeBack: .importedAccount(id: imported.id)),
            usageRoots: []
        )
    }

    private static func importedUserId(_ imported: ImportedCodexAccount) -> String? {
        guard let colon = imported.id.firstIndex(of: ":") else { return nil }
        return nonEmpty(String(imported.id[imported.id.index(after: colon)...]))
    }

    // MARK: - ccpm

    private static func ccpmAccount(_ profile: CCPMProfileDescriptor) -> MonitoredAccount? {
        let dir = URL(fileURLWithPath: profile.dir, isDirectory: true)
        switch profile.runtime {
        case .codex:
            return ccpmCodexAccount(profile, dir: dir)
        case .claude:
            let providerName = profile.provider ?? "anthropic"
            switch providerName {
            case "anthropic":
                return ccpmClaudeAccount(profile, dir: dir)
            case "kimi":
                return ccpmAPIKeyAccount(profile, provider: .kimi, dir: dir)
            case "glm":
                return ccpmAPIKeyAccount(profile, provider: .glm, dir: dir)
            case "ollama":
                return ccpmOllamaAccount(profile, dir: dir)
            default:
                print("[AccountCatalog] ignoring ccpm profile \(profile.name): unknown provider \(providerName)")
                return nil
            }
        }
    }

    private static func ccpmCodexAccount(_ profile: CCPMProfileDescriptor, dir: URL) -> MonitoredAccount {
        let id = AccountID(provider: .codex, source: .ccpm(profile: profile.name))
        let roots = [
            dir.appendingPathComponent("sessions", isDirectory: true),
            dir.appendingPathComponent("archived_sessions", isDirectory: true)
        ]
        var identity = AccountIdentity(profileName: profile.name, profileDir: profile.dir, isDefaultProfile: profile.isDefault)
        guard profile.authMethod == .oauth else {
            return MonitoredAccount(
                id: id, provider: .codex, source: .ccpm(profile: profile.name), identity: identity,
                credential: .unavailable(reason: "ccpm auth \(profile.authMethod.rawValue): no quota API"),
                usageRoots: roots
            )
        }
        do {
            let account = try CodexAuth.load(from: URL(fileURLWithPath: profile.authFilePath))
            identity.email = account.email
            identity.plan = account.planType
            identity.fingerprint = nonEmpty(account.accountId) ?? account.email
            return MonitoredAccount(
                id: id, provider: .codex, source: .ccpm(profile: profile.name), identity: identity,
                credential: .codexOAuth(account, writeBack: .codexAuthJSONAt(path: profile.authFilePath)),
                usageRoots: roots
            )
        } catch {
            return MonitoredAccount(
                id: id, provider: .codex, source: .ccpm(profile: profile.name), identity: identity,
                credential: .unavailable(reason: "\(error)"),
                usageRoots: roots
            )
        }
    }

    private static func ccpmClaudeAccount(_ profile: CCPMProfileDescriptor, dir: URL) -> MonitoredAccount {
        let id = AccountID(provider: .claude, source: .ccpm(profile: profile.name))
        let roots = [dir.appendingPathComponent("projects", isDirectory: true)]
        let claudeIdentity = CCPMClaudeProfileStore.readIdentity(profileDir: profile.dir)
        var identity = AccountIdentity(
            email: claudeIdentity.email,
            displayName: claudeIdentity.displayName,
            plan: claudeIdentity.organizationType?.replacingOccurrences(of: "_", with: " ").capitalized,
            profileName: profile.name,
            profileDir: profile.dir,
            isDefaultProfile: profile.isDefault,
            fingerprint: claudeIdentity.email
        )
        guard profile.authMethod == .oauth else {
            return MonitoredAccount(
                id: id, provider: .claude, source: .ccpm(profile: profile.name), identity: identity,
                credential: .unavailable(reason: "ccpm auth \(profile.authMethod.rawValue): no quota API"),
                usageRoots: roots
            )
        }
        do {
            let (account, storage) = try CCPMClaudeProfileStore.loadOAuthAccount(profile: profile, identity: claudeIdentity)
            identity.email = account.email ?? identity.email
            identity.plan = account.subscriptionType ?? identity.plan
            identity.fingerprint = account.email ?? identity.fingerprint
            return MonitoredAccount(
                id: id, provider: .claude, source: .ccpm(profile: profile.name), identity: identity,
                credential: .claudeOAuth(account, storage: storage),
                usageRoots: roots
            )
        } catch {
            return MonitoredAccount(
                id: id, provider: .claude, source: .ccpm(profile: profile.name), identity: identity,
                credential: .unavailable(reason: "\(error)"),
                usageRoots: roots
            )
        }
    }

    private static func ccpmAPIKeyAccount(_ profile: CCPMProfileDescriptor, provider: Provider, dir: URL) -> MonitoredAccount {
        let id = AccountID(provider: provider, source: .ccpm(profile: profile.name))
        let roots = [dir.appendingPathComponent("projects", isDirectory: true)]
        let baseURL = profile.anthropicBaseURL ?? provider.descriptor.defaultBaseURL!
        let identity = AccountIdentity(
            displayName: nil,
            profileName: profile.name,
            profileDir: profile.dir,
            isDefaultProfile: profile.isDefault,
            fingerprint: baseURL.host
        )
        guard let key = CCPMKeystore.apiKey(profile: profile.name), !key.isEmpty else {
            return MonitoredAccount(
                id: id, provider: provider, source: .ccpm(profile: profile.name), identity: identity,
                credential: .unavailable(reason: "no API key in ccpm keystore"),
                usageRoots: roots
            )
        }
        return MonitoredAccount(
            id: id, provider: provider, source: .ccpm(profile: profile.name), identity: identity,
            credential: .apiKey(key, baseURL: baseURL),
            usageRoots: roots
        )
    }

    private static func ccpmOllamaAccount(_ profile: CCPMProfileDescriptor, dir: URL) -> MonitoredAccount {
        let id = AccountID(provider: .ollama, source: .ccpm(profile: profile.name))
        let roots = [dir.appendingPathComponent("projects", isDirectory: true)]
        let baseURL = profile.anthropicBaseURL ?? Provider.ollama.descriptor.defaultBaseURL!
        let identity = AccountIdentity(
            profileName: profile.name,
            profileDir: profile.dir,
            isDefaultProfile: profile.isDefault,
            fingerprint: nil
        )
        return MonitoredAccount(
            id: id, provider: .ollama, source: .ccpm(profile: profile.name), identity: identity,
            credential: .ollamaCookie(cookieHeader: OllamaCookieStore.load(profile: profile.name), baseURL: baseURL),
            usageRoots: roots
        )
    }

    private static func profileOrder(_ lhs: CCPMProfileDescriptor, _ rhs: CCPMProfileDescriptor) -> Bool {
        if lhs.isDefault != rhs.isDefault { return lhs.isDefault }
        switch (lhs.lastUsed, rhs.lastUsed) {
        case let (l?, r?) where l != r:
            return l > r
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    // MARK: - Codex identity mirroring

    /// Imported and ccpm Codex accounts that are the same ChatGPT identity as
    /// the default login (or as a visible imported account) reuse that quota
    /// state instead of hitting the API twice.
    private static func applyCodexMirrors(_ accounts: inout [MonitoredAccount], defaultCodex: MonitoredAccount) {
        let primary = codexIdentity(of: defaultCodex)
        var importedIdentities: [(AccountID, (String, String?))] = []
        for index in accounts.indices where accounts[index].provider == .codex {
            let account = accounts[index]
            guard let identity = codexIdentity(of: account) else { continue }
            switch account.source {
            case .defaultLogin:
                continue
            case .importedCodex:
                if let primary, identitiesMatch(identity, primary) {
                    accounts[index].mirrorsAccount = defaultCodex.id
                } else {
                    importedIdentities.append((account.id, identity))
                }
            case .ccpm:
                if let primary, identitiesMatch(identity, primary) {
                    accounts[index].mirrorsAccount = defaultCodex.id
                } else if let match = importedIdentities.first(where: { identitiesMatch(identity, $0.1) }) {
                    accounts[index].mirrorsAccount = match.0
                }
            }
        }
    }

    private static func codexIdentity(of account: MonitoredAccount) -> (String, String?)? {
        guard case .codexOAuth(let codex, _) = account.credential,
              let accountId = nonEmpty(codex.accountId)
        else { return nil }
        return (accountId, nonEmpty(codex.chatgptUserId))
    }

    private static func identitiesMatch(_ lhs: (String, String?), _ rhs: (String, String?)) -> Bool {
        guard lhs.0 == rhs.0 else { return false }
        if let l = lhs.1, let r = rhs.1 { return l == r }
        return true
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}
