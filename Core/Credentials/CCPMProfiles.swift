import CryptoKit
import Foundation

nonisolated enum CCPMRuntime: String, Sendable, Codable {
    case claude
    case codex
}

nonisolated enum CCPMAuthMethod: String, Sendable, Codable {
    case oauth
    case apiKey = "api_key"
    case unknown
}

/// One entry of `~/.ccpm/config.json`. `provider` is the explicit field the
/// ccpm fork writes for Claude-runtime profiles; empty means Anthropic.
nonisolated struct CCPMProfileDescriptor: Sendable, Equatable, Identifiable {
    var id: String { name }

    var name: String
    var dir: String
    var runtime: CCPMRuntime
    var authMethod: CCPMAuthMethod
    var provider: String?
    var env: [String: String]
    var isDefault: Bool
    var lastUsed: Date?

    var authFilePath: String {
        URL(fileURLWithPath: dir).appendingPathComponent("auth.json").path
    }

    var credentialsFilePath: String {
        URL(fileURLWithPath: dir).appendingPathComponent(".credentials.json").path
    }

    var anthropicBaseURL: URL? {
        guard let raw = env["ANTHROPIC_BASE_URL"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else { return nil }
        return URL(string: raw)
    }
}

nonisolated enum CCPMProfileCatalog {
    nonisolated static func loadProfiles() -> [CCPMProfileDescriptor] {
        guard let payload = loadConfigPayload() else { return [] }

        return payload.profiles.keys.sorted().compactMap { key in
            guard let profile = payload.profiles[key] else { return nil }
            let runtimeName = profile.runtime?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let effectiveRuntime = runtimeName.flatMap { $0.isEmpty ? nil : $0 } ?? CCPMRuntime.claude.rawValue
            guard let runtime = CCPMRuntime(rawValue: effectiveRuntime) else { return nil }
            let provider = profile.provider?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

            return CCPMProfileDescriptor(
                name: profile.name.flatMap { $0.isEmpty ? nil : $0 } ?? key,
                dir: expandedPath(profile.dir),
                runtime: runtime,
                authMethod: CCPMAuthMethod(rawValue: profile.authMethod ?? "") ?? .unknown,
                provider: provider.flatMap { $0.isEmpty ? nil : $0 },
                env: profile.env ?? [:],
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
        var provider: String?
        var env: [String: String]?
        var lastUsed: String?

        enum CodingKeys: String, CodingKey {
            case name
            case dir
            case runtime
            case authMethod = "auth_method"
            case provider
            case env
            case lastUsed = "last_used"
        }
    }

    private static func loadConfigPayload() -> ConfigPayload? {
        let url = configURL()
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ConfigPayload.self, from: data)
    }

    nonisolated static func configURL() -> URL {
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

nonisolated struct CCPMClaudeIdentity: Sendable, Equatable {
    var email: String?
    var displayName: String?
    var organizationType: String?
}

/// Claude Code credential lookup for a ccpm profile directory. Keychain
/// service naming follows ccpm / Claude Code 2.1.56+: `Claude Code-credentials-<sha256(dir)[:8]>`.
nonisolated enum CCPMClaudeProfileStore {
    private static let keychainServicePrefix = "Claude Code-credentials"

    nonisolated static func readIdentity(profileDir: String) -> CCPMClaudeIdentity {
        let url = URL(fileURLWithPath: profileDir).appendingPathComponent(".claude.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["oauthAccount"] as? [String: Any]
        else {
            return CCPMClaudeIdentity()
        }
        return CCPMClaudeIdentity(
            email: oauth["emailAddress"] as? String,
            displayName: oauth["displayName"] as? String,
            organizationType: oauth["organizationType"] as? String
        )
    }

    nonisolated static func loadOAuthAccount(
        profile: CCPMProfileDescriptor,
        identity: CCPMClaudeIdentity
    ) throws -> (ClaudeAccount, ClaudeCredentialStorage) {
        let service = keychainService(profileDir: profile.dir)
        if let data = readKeychainData(service: service) {
            let account = try parseOAuthPayload(data: data, source: .keychain, identity: identity)
            return (account, .keychain(service: service))
        }

        let filePath = profile.credentialsFilePath
        if FileManager.default.fileExists(atPath: filePath) {
            let data = try Data(contentsOf: URL(fileURLWithPath: filePath))
            let account = try parseOAuthPayload(data: data, source: .file, identity: identity)
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
        identity: CCPMClaudeIdentity
    ) throws -> ClaudeAccount {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CredentialError.decodeFailed("ccpm credential is not a JSON object")
        }

        if let oauth = root["claudeAiOauth"] as? [String: Any] {
            let expiresAt = parseExpiresAt(oauth["expiresAt"] ?? oauth["expires_at"])
            return ClaudeAccount(
                source: source,
                email: oauth["emailAddress"] as? String ?? oauth["email"] as? String ?? identity.email,
                subscriptionType: oauth["subscriptionType"] as? String ?? identity.organizationType,
                expiresAt: expiresAt,
                expiredGuess: expiresAt.map { $0 < Date() } ?? false,
                accessToken: oauth["accessToken"] as? String ?? oauth["access_token"] as? String,
                refreshToken: oauth["refreshToken"] as? String ?? oauth["refresh_token"] as? String
            )
        }

        let accessToken = root["accessToken"] as? String ?? root["access_token"] as? String
        let refreshToken = root["refreshToken"] as? String ?? root["refresh_token"] as? String
        guard accessToken?.isEmpty == false else {
            throw CredentialError.decodeFailed("ccpm credential has no access token")
        }
        let expiresAt = parseExpiresAt(root["expiresAt"] ?? root["expires_at"])
        return ClaudeAccount(
            source: source,
            email: identity.email,
            subscriptionType: identity.organizationType,
            expiresAt: expiresAt,
            expiredGuess: expiresAt.map { $0 < Date() } ?? false,
            accessToken: accessToken,
            refreshToken: refreshToken
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

/// Runs the ccpm CLI on the user's behalf for card actions. GUI apps do not
/// inherit the shell PATH, so the binary is located explicitly first.
nonisolated enum CCPMCommand {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    nonisolated static func resolveBinary() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "/opt/homebrew/bin/ccpm",
            "/usr/local/bin/ccpm",
            "\(home)/.npm-global/bin/ccpm",
            "\(home)/go/bin/ccpm",
            "\(home)/.local/bin/ccpm",
            "\(home)/.volta/bin/ccpm"
        ]
        if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return found
        }
        // Last resort: ask a login shell, which has the user's PATH.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "which ccpm"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return output.isEmpty ? nil : output
    }

    /// `ccpm set-default <profile>`; throws with stderr when the CLI fails.
    nonisolated static func setDefault(profile: String) async throws {
        guard let binary = resolveBinary() else {
            throw Failure(description: "ccpm not found; install it or add it to PATH")
        }
        try await Task.detached(priority: .userInitiated) {
            try runProcess(binary, arguments: ["set-default", profile], timeout: 20)
        }.value
    }

    /// Opens Terminal.app and runs `ccpm run <profile>` in a new window.
    nonisolated static func openInTerminal(profile: String) throws {
        let escaped = shellEscape(profile)
        let script = "ccpm run \(escaped)"
        // AppleScript string: escape backslashes and double quotes.
        let appleScriptString = script
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        try runProcess(
            "/usr/bin/osascript",
            arguments: [
                "-e", "tell application \"Terminal\" to do script \"\(appleScriptString)\"",
                "-e", "tell application \"Terminal\" to activate"
            ],
            timeout: 10
        )
    }

    nonisolated static func shellEscape(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    nonisolated private static func runProcess(_ executable: String, arguments: [String], timeout: TimeInterval) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let stderr = Pipe()
        process.standardOutput = Pipe()
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            throw Failure(description: "could not launch \(executable): \(error.localizedDescription)")
        }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            throw Failure(description: "\(arguments.first ?? executable) timed out after \(Int(timeout))s")
        }
        guard process.terminationStatus == 0 else {
            let message = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw Failure(description: message.isEmpty ? "exit \(process.terminationStatus)" : message)
        }
    }
}
