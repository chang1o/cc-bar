import CryptoKit
import Foundation

/// One entry of `~/.ccpm/config.json`. `provider` is the explicit field the ccpm fork
/// writes for Claude-runtime profiles; a Codex-runtime profile is reported as "codex".
nonisolated struct CCPMProfile: Sendable, Hashable {
    let name: String
    /// "anthropic" | "codex" | "kimi" | "glm" | "ollama" (anything else is ignored by discovery)
    let provider: String
    let displayName: String?
    let baseURL: String?
    let directory: URL
    let isDefault: Bool
    let usesAPIKey: Bool
    let lastUsed: Date?

    var label: String { displayName ?? name }

    var authFileURL: URL { directory.appendingPathComponent("auth.json") }
    var credentialsFileURL: URL { directory.appendingPathComponent(".credentials.json") }

    var resolvedBaseURL: URL? {
        guard let raw = baseURL?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        return URL(string: raw)
    }
}

nonisolated enum CCPMProfileCatalog {
    nonisolated static func load() -> [CCPMProfile] {
        guard let payload = loadConfigPayload() else { return [] }
        let profiles: [CCPMProfile] = payload.profiles.keys.sorted().compactMap { key in
            guard let profile = payload.profiles[key] else { return nil }
            let runtime = (profile.runtime ?? "claude").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let provider: String
            if runtime == "codex" {
                provider = "codex"
            } else {
                let raw = (profile.provider ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                provider = raw.isEmpty ? "anthropic" : raw
            }
            let configuredName = profile.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return CCPMProfile(
                name: key,
                provider: provider,
                displayName: (configuredName.isEmpty || configuredName == key) ? nil : configuredName,
                baseURL: profile.env?["ANTHROPIC_BASE_URL"],
                directory: URL(fileURLWithPath: expandedPath(profile.dir), isDirectory: true),
                isDefault: payload.defaultProfile == key,
                usesAPIKey: profile.authMethod == "api_key",
                lastUsed: parseDate(profile.lastUsed)
            )
        }
        return profiles.sorted(by: order)
    }

    nonisolated static func homeDirectory() -> URL {
        if let ccpmHome = ProcessInfo.processInfo.environment["CCPM_HOME"],
           !ccpmHome.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: expandedPath(ccpmHome), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ccpm", isDirectory: true)
    }

    nonisolated static func configURL() -> URL {
        homeDirectory().appendingPathComponent("config.json")
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

    private static func order(_ lhs: CCPMProfile, _ rhs: CCPMProfile) -> Bool {
        if lhs.isDefault != rhs.isDefault { return lhs.isDefault }
        switch (lhs.lastUsed, rhs.lastUsed) {
        case let (l?, r?) where l != r: return l > r
        case (_?, nil): return true
        case (nil, _?): return false
        default: return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
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
        var provider: String?
        var env: [String: String]?
        var lastUsed: String?

        enum CodingKeys: String, CodingKey {
            case name, dir, runtime, provider, env
            case authMethod = "auth_method"
            case lastUsed = "last_used"
        }
    }

    private static func loadConfigPayload() -> ConfigPayload? {
        guard let data = try? Data(contentsOf: configURL()) else { return nil }
        return try? JSONDecoder().decode(ConfigPayload.self, from: data)
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

/// Extra JSONL roots contributed by ccpm profiles. Claude Code writes its logs under
/// `CLAUDE_CONFIG_DIR/projects`, Codex under `CODEX_HOME/sessions`.
nonisolated enum CCPMUsageRoots {
    nonisolated static func claude() -> [URL] {
        CCPMProfileCatalog.load()
            .filter { $0.provider == "anthropic" }
            .map { $0.directory.appendingPathComponent("projects", isDirectory: true) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    nonisolated static func codex() -> [URL] {
        CCPMProfileCatalog.load()
            .filter { $0.provider == "codex" }
            .flatMap {
                [
                    $0.directory.appendingPathComponent("sessions", isDirectory: true),
                    $0.directory.appendingPathComponent("archived_sessions", isDirectory: true),
                ]
            }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Appends ccpm roots to the given default roots, dropping duplicates by path.
    nonisolated static func merged(_ defaults: [URL], with extra: [URL]) -> [URL] {
        var seen = Set<String>()
        return (defaults + extra).filter { seen.insert($0.standardizedFileURL.path).inserted }
    }
}

nonisolated struct CCPMClaudeIdentity: Sendable, Equatable {
    var email: String?
    var displayName: String?
    var organizationType: String?
}

/// Claude Code credential lookup for a ccpm profile directory. Keychain service naming
/// follows ccpm / Claude Code 2.1.56+: `Claude Code-credentials-<sha256(dir)[:8]>`.
/// Items were created by Claude Code, so they are read through the `security` CLI
/// (SecItem would need an authorization prompt for a foreign item).
nonisolated enum CCPMClaudeProfileStore {
    private static let keychainServicePrefix = "Claude Code-credentials"

    nonisolated static func readIdentity(profile: CCPMProfile) -> CCPMClaudeIdentity {
        let url = profile.directory.appendingPathComponent(".claude.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["oauthAccount"] as? [String: Any]
        else { return CCPMClaudeIdentity() }
        return CCPMClaudeIdentity(
            email: oauth["emailAddress"] as? String,
            displayName: oauth["displayName"] as? String,
            organizationType: oauth["organizationType"] as? String
        )
    }

    nonisolated static func loadOAuthAccount(profile: CCPMProfile, identity: CCPMClaudeIdentity) throws -> ClaudeAccount {
        if let data = readKeychainData(service: keychainService(profile: profile)) {
            return try parseOAuthPayload(data: data, source: .keychain, identity: identity)
        }
        let fileURL = profile.credentialsFileURL
        if FileManager.default.fileExists(atPath: fileURL.path) {
            return try parseOAuthPayload(data: try Data(contentsOf: fileURL), source: .file, identity: identity)
        }
        throw CredentialError.fileNotFound("ccpm OAuth credentials for profile \(profile.name)")
    }

    nonisolated static func keychainService(profile: CCPMProfile) -> String {
        let path = profile.directory.standardizedFileURL.path
        let digest = SHA256.hash(data: Data(path.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "\(keychainServicePrefix)-\(hex.prefix(8))"
    }

    private static func readKeychainData(service: String) -> Data? {
        for account in [NSUserName(), "Claude Code", "claude-code", "default"] where !account.isEmpty {
            if let data = SecurityCLI.findGenericPassword(service: service, account: account) { return data }
        }
        return SecurityCLI.findGenericPassword(service: service, account: nil)
    }

    private static func parseOAuthPayload(data: Data, source: CredentialSource, identity: CCPMClaudeIdentity) throws -> ClaudeAccount {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CredentialError.decodeFailed("ccpm credential is not a JSON object")
        }
        let oauth = root["claudeAiOauth"] as? [String: Any] ?? root
        let accessToken = oauth["accessToken"] as? String ?? oauth["access_token"] as? String
        guard accessToken?.isEmpty == false else {
            throw CredentialError.decodeFailed("ccpm credential has no access token")
        }
        let expiresAt = parseExpiresAt(oauth["expiresAt"] ?? oauth["expires_at"])
        return ClaudeAccount(
            source: source,
            email: oauth["emailAddress"] as? String ?? oauth["email"] as? String ?? identity.email,
            subscriptionType: oauth["subscriptionType"] as? String ?? identity.organizationType,
            expiresAt: expiresAt,
            expiredGuess: expiresAt.map { $0 < Date() } ?? false,
            accessToken: accessToken,
            refreshToken: oauth["refreshToken"] as? String ?? oauth["refresh_token"] as? String
        )
    }

    private static func parseExpiresAt(_ raw: Any?) -> Date? {
        if let number = QuotaJSON.double(raw) {
            return Date(timeIntervalSince1970: number > 10_000_000_000 ? number / 1000 : number)
        }
        return QuotaJSON.isoDate(raw)
    }
}

/// `/usr/bin/security find-generic-password -w` wrapper for Keychain items created by
/// other processes (Claude Code, go-keyring). Reading our own items uses SecItem instead.
nonisolated enum SecurityCLI {
    nonisolated static func findGenericPassword(service: String, account: String?) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        var arguments = ["find-generic-password", "-s", service]
        if let account, !account.isEmpty { arguments += ["-a", account] }
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
        guard let text = String(data: output, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty
        else { return nil }
        return Data(text.utf8)
    }
}

/// Runs the ccpm CLI on the user's behalf for card actions. GUI apps do not inherit the
/// shell PATH, so the binary is located explicitly first. Callers run these off the main actor.
nonisolated enum CCPMCommand {
    nonisolated static func resolveBinary() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "/opt/homebrew/bin/ccpm",
            "/usr/local/bin/ccpm",
            "\(home)/.npm-global/bin/ccpm",
            "\(home)/go/bin/ccpm",
            "\(home)/.local/bin/ccpm",
            "\(home)/.volta/bin/ccpm",
        ]
        if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return found
        }
        let output = run("/bin/zsh", arguments: ["-lc", "which ccpm"], timeout: 10).output
        return output.isEmpty ? nil : output
    }

    /// `ccpm set-default <profile>`; false when the binary is missing or the CLI fails.
    nonisolated static func setDefault(profile: String) -> Bool {
        guard let binary = resolveBinary() else { return false }
        return run(binary, arguments: ["set-default", profile], timeout: 20).ok
    }

    /// Opens Terminal.app and runs `ccpm run <profile>` in a new window.
    nonisolated static func openInTerminal(profile: String) {
        let command = "ccpm run " + shellEscape(profile)
        let appleScriptString = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        _ = run(
            "/usr/bin/osascript",
            arguments: [
                "-e", "tell application \"Terminal\" to do script \"\(appleScriptString)\"",
                "-e", "tell application \"Terminal\" to activate",
            ],
            timeout: 10
        )
    }

    nonisolated static func shellEscape(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    nonisolated private static func run(_ executable: String, arguments: [String], timeout: TimeInterval) -> (ok: Bool, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return (false, "") }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            return (false, "")
        }
        let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (process.terminationStatus == 0, output)
    }
}
