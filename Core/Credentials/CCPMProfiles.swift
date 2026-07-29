import CryptoKit
import Foundation

enum CCPMRuntime: String, Sendable, Codable {
    case claude
    case codex
}

enum CCPMAuthMethod: String, Sendable, Codable {
    case oauth
    case apiKey = "api_key"
    case unknown
}

struct CCPMProfileDescriptor: Sendable, Equatable, Identifiable {
    var id: String { name }

    var name: String
    var dir: String
    var runtime: CCPMRuntime
    var authMethod: CCPMAuthMethod
    var isDefault: Bool
    var lastUsed: Date?
}

enum CCPMProfileCatalog {
    nonisolated static func loadProfiles() -> [CCPMProfileDescriptor] {
        guard let payload = loadConfigPayload() else { return [] }

        return payload.profiles.keys.sorted().compactMap { key in
            guard let profile = payload.profiles[key] else { return nil }
            let runtimeName = profile.runtime?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let effectiveRuntime = runtimeName.flatMap { $0.isEmpty ? nil : $0 } ?? CCPMRuntime.claude.rawValue
            guard let runtime = CCPMRuntime(rawValue: effectiveRuntime) else { return nil }

            return CCPMProfileDescriptor(
                name: profile.name.flatMap { $0.isEmpty ? nil : $0 } ?? key,
                dir: expandedPath(profile.dir),
                runtime: runtime,
                authMethod: CCPMAuthMethod(rawValue: profile.authMethod ?? "") ?? .unknown,
                isDefault: payload.defaultProfile == key,
                lastUsed: parseDate(profile.lastUsed)
            )
        }
    }

    nonisolated static func expandedPath(_ path: String) -> String {
        let expanded: String
        if path == "~" {
            expanded = FileManager.default.homeDirectoryForCurrentUser.path
        } else if path.hasPrefix("~/") {
            expanded = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(String(path.dropFirst(2))).path
        } else {
            expanded = path
        }
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
    }

    private struct ConfigPayload: Decodable {
        var defaultProfile: String?
        var profiles: [String: ConfigProfile]

        enum CodingKeys: String, CodingKey {
            case defaultProfile = "default_profile"
            case profiles
        }
    }

    private struct ConfigProfile: Decodable {
        var name: String?
        var dir: String
        var runtime: String?
        var authMethod: String?
        var lastUsed: String?

        enum CodingKeys: String, CodingKey {
            case name
            case dir
            case runtime
            case authMethod = "auth_method"
            case lastUsed = "last_used"
        }
    }

    private static func loadConfigPayload() -> ConfigPayload? {
        let url = configURL()
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ConfigPayload.self, from: data)
    }

    private static func configURL() -> URL {
        if let ccpmHome = ProcessInfo.processInfo.environment["CCPM_HOME"],
           !ccpmHome.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: expandedPath(ccpmHome)).appendingPathComponent("config.json")
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ccpm/config.json")
    }

    private static func parseDate(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: raw) { return date }
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: raw)
    }
}

struct CCPMClaudeProfile: Sendable, Equatable, Identifiable {
    var id: String { name }

    var name: String
    var dir: String
    var authMethod: CCPMAuthMethod
    var isDefault: Bool
    var email: String?
    var displayName: String?
    var organizationType: String?
    var lastUsed: Date?

    var keychainService: String {
        CCPMClaudeProfileStore.keychainService(profileDir: dir)
    }

    var credentialsFilePath: String {
        URL(fileURLWithPath: dir).appendingPathComponent(".credentials.json").path
    }
}

struct CCPMCodexProfile: Sendable, Equatable, Identifiable {
    var id: String { name }

    var name: String
    var dir: String
    var authMethod: CCPMAuthMethod
    var isDefault: Bool
    var email: String?
    var planType: String?
    var accountId: String?
    var chatgptUserId: String?
    var lastUsed: Date?

    var authFilePath: String {
        URL(fileURLWithPath: dir).appendingPathComponent("auth.json").path
    }
}

enum CCPMClaudeProfileStore {
    private static let keychainServicePrefix = "Claude Code-credentials"

    nonisolated static func loadProfiles() -> [CCPMClaudeProfile] {
        CCPMProfileCatalog.loadProfiles()
            .filter { $0.runtime == .claude }
            .map { descriptor in
                let identity = readIdentity(profileDir: descriptor.dir)
                return CCPMClaudeProfile(
                    name: descriptor.name,
                    dir: descriptor.dir,
                    authMethod: descriptor.authMethod,
                    isDefault: descriptor.isDefault,
                    email: identity.email,
                    displayName: identity.displayName,
                    organizationType: identity.organizationType,
                    lastUsed: descriptor.lastUsed
                )
            }
    }

    nonisolated static func loadAccount(profile: CCPMClaudeProfile) throws -> (ClaudeAccount, ClaudeCredentialStorage) {
        guard profile.authMethod == .oauth else {
            throw CredentialError.decodeFailed("unsupported ccpm auth method: \(profile.authMethod.rawValue)")
        }

        let service = keychainService(profileDir: profile.dir)
        if let data = readKeychainData(service: service) {
            let account = try parseOAuthPayload(data: data, source: .keychain, profile: profile)
            return (account, .keychain(service: service))
        }

        let filePath = profile.credentialsFilePath
        if FileManager.default.fileExists(atPath: filePath) {
            let data = try Data(contentsOf: URL(fileURLWithPath: filePath))
            let account = try parseOAuthPayload(data: data, source: .file, profile: profile)
            return (account, .file(path: filePath))
        }

        throw CredentialError.fileNotFound("ccpm OAuth credentials for profile \(profile.name)")
    }

    nonisolated static func keychainService(profileDir: String) -> String {
        let path = CCPMProfileCatalog.expandedPath(profileDir)
        let digest = SHA256.hash(data: Data(path.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "\(keychainServicePrefix)-\(hex.prefix(8))"
    }

    private struct ProfileIdentity {
        var email: String?
        var displayName: String?
        var organizationType: String?
    }

    private static func readIdentity(profileDir: String) -> ProfileIdentity {
        let url = URL(fileURLWithPath: profileDir).appendingPathComponent(".claude.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["oauthAccount"] as? [String: Any]
        else {
            return ProfileIdentity()
        }
        return ProfileIdentity(
            email: oauth["emailAddress"] as? String,
            displayName: oauth["displayName"] as? String,
            organizationType: oauth["organizationType"] as? String
        )
    }

    private static func readKeychainData(service: String) -> Data? {
        for account in keychainAccounts() {
            if let data = readKeychainData(service: service, account: account) {
                return data
            }
        }
        return readKeychainData(service: service, account: nil)
    }

    private static func readKeychainData(service: String, account: String?) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        var arguments = ["find-generic-password", "-s", service]
        if let account, !account.isEmpty {
            arguments.append(contentsOf: ["-a", account])
        }
        arguments.append("-w")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        guard !output.isEmpty else { return nil }
        let trimmed = String(data: output, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.data(using: .utf8)
    }

    private static func keychainAccounts() -> [String] {
        var accounts = [NSUserName()]
        accounts.append(contentsOf: ["Claude Code", "claude-code", "default"])
        var seen = Set<String>()
        return accounts.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private static func parseOAuthPayload(
        data: Data,
        source: CredentialSource,
        profile: CCPMClaudeProfile
    ) throws -> ClaudeAccount {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CredentialError.decodeFailed("ccpm credential is not a JSON object")
        }

        if let oauth = root["claudeAiOauth"] as? [String: Any] {
            return parseClaudeAiOauth(oauth, source: source, profile: profile)
        }

        let accessToken = root["accessToken"] as? String ?? root["access_token"] as? String
        let refreshToken = root["refreshToken"] as? String ?? root["refresh_token"] as? String
        guard accessToken?.isEmpty == false else {
            throw CredentialError.decodeFailed("ccpm credential has no access token")
        }
        let expiresAt = parseExpiresAt(root["expiresAt"] ?? root["expires_at"])
        return ClaudeAccount(
            source: source,
            email: profile.email,
            subscriptionType: profile.organizationType,
            expiresAt: expiresAt,
            expiredGuess: expiresAt.map { $0 < Date() } ?? false,
            accessToken: accessToken,
            refreshToken: refreshToken
        )
    }

    private static func parseClaudeAiOauth(
        _ oauth: [String: Any],
        source: CredentialSource,
        profile: CCPMClaudeProfile
    ) -> ClaudeAccount {
        let email = oauth["emailAddress"] as? String
            ?? oauth["email"] as? String
            ?? profile.email
        let expiresAt = parseExpiresAt(oauth["expiresAt"] ?? oauth["expires_at"])
        return ClaudeAccount(
            source: source,
            email: email,
            subscriptionType: oauth["subscriptionType"] as? String ?? profile.organizationType,
            expiresAt: expiresAt,
            expiredGuess: expiresAt.map { $0 < Date() } ?? false,
            accessToken: oauth["accessToken"] as? String ?? oauth["access_token"] as? String,
            refreshToken: oauth["refreshToken"] as? String ?? oauth["refresh_token"] as? String
        )
    }

    private static func parseExpiresAt(_ raw: Any?) -> Date? {
        if let number = raw as? Double {
            return Date(timeIntervalSince1970: number > 10_000_000_000 ? number / 1000 : number)
        }
        if let integer = raw as? Int {
            let number = Double(integer)
            return Date(timeIntervalSince1970: number > 10_000_000_000 ? number / 1000 : number)
        }
        if let string = raw as? String {
            if let number = Double(string) {
                return Date(timeIntervalSince1970: number > 10_000_000_000 ? number / 1000 : number)
            }
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = iso.date(from: string) { return date }
            iso.formatOptions = [.withInternetDateTime]
            return iso.date(from: string)
        }
        return nil
    }
}

enum CCPMCodexProfileStore {
    nonisolated static func loadProfiles() -> [CCPMCodexProfile] {
        CCPMProfileCatalog.loadProfiles()
            .filter { $0.runtime == .codex }
            .map { descriptor in
                let profile = CCPMCodexProfile(
                    name: descriptor.name,
                    dir: descriptor.dir,
                    authMethod: descriptor.authMethod,
                    isDefault: descriptor.isDefault,
                    email: nil,
                    planType: nil,
                    accountId: nil,
                    chatgptUserId: nil,
                    lastUsed: descriptor.lastUsed
                )
                guard let account = try? loadAccount(profile: profile) else { return profile }
                var hydrated = profile
                hydrated.email = account.email
                hydrated.planType = account.planType
                hydrated.accountId = account.accountId
                hydrated.chatgptUserId = account.chatgptUserId
                return hydrated
            }
    }

    nonisolated static func loadAccount(profile: CCPMCodexProfile) throws -> CodexAccount {
        guard profile.authMethod == .oauth else {
            throw CredentialError.decodeFailed("unsupported ccpm auth method: \(profile.authMethod.rawValue)")
        }
        return try CodexAuth.load(from: URL(fileURLWithPath: profile.authFilePath))
    }
}
