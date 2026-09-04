import Foundation

enum CodexAuth {
    nonisolated static func load() throws -> CodexAccount {
        try load(from: authFileURL())
    }

    /// Parses any Codex `auth.json`, e.g. a ccpm profile's `CODEX_HOME/auth.json`.
    nonisolated static func load(from url: URL) throws -> CodexAccount {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CredentialError.fileNotFound(url.path)
        }
        let data = try Data(contentsOf: url)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CredentialError.invalidJSON(url.path)
        }
        let tokens = root["tokens"] as? [String: Any] ?? [:]
        let idToken = tokens["id_token"] as? String
        let accessToken = tokens["access_token"] as? String
        let refreshToken = tokens["refresh_token"] as? String
        let lastRefresh = parseDate(root["last_refresh"])

        // personal access token 形态：{"OPENAI_API_KEY": null, "personal_access_token": "at-..."}
        // 这是 Codex 工作区访问令牌，不透明、无 JWT，仅当没有可用 OAuth access_token 时才采用，
        // 避免覆盖正常登录态。身份（email/plan/account_id）留空，由首次取数从 wham/usage 响应回填。
        if nonEmpty(accessToken) == nil,
           let pat = nonEmpty(root["personal_access_token"] as? String) {
            return CodexAccount(
                email: nil,
                planType: nil,
                accountId: nil,
                chatgptUserId: nil,
                lastRefresh: lastRefresh,
                expiredGuess: false,
                rawClaimKeys: [],
                accessToken: pat,
                refreshToken: nil,
                idToken: nil,
                isPersonalAccessToken: true
            )
        }
        let idClaims = idToken.flatMap { JWT.decodePayload($0) }
        let accessClaims = accessToken.flatMap { JWT.decodePayload($0) }

        var email: String?
        var planType: String?
        var claimKeys: [String] = []
        if let claims = idClaims {
            claimKeys = Array(claims.keys).sorted()
            email = claims["email"] as? String
            if let auth = claims["https://api.openai.com/auth"] as? [String: Any] {
                planType = auth["chatgpt_plan_type"] as? String
            }
            if planType == nil {
                planType = claims["chatgpt_plan_type"] as? String
            }
        }
        if planType == nil, let claims = accessClaims,
           let auth = claims["https://api.openai.com/auth"] as? [String: Any] {
            planType = auth["chatgpt_plan_type"] as? String
        }
        let accountId = nonEmpty(tokens["account_id"] as? String)
            ?? authClaim("chatgpt_account_id", from: accessClaims)
            ?? authClaim("chatgpt_account_id", from: idClaims)
        let chatgptUserId = authClaim("chatgpt_user_id", from: accessClaims)
            ?? authClaim("chatgpt_user_id", from: idClaims)

        let expiredGuess: Bool = {
            guard let lastRefresh else { return true }
            return Date().timeIntervalSince(lastRefresh) > 8 * 24 * 3600
        }()

        return CodexAccount(
            email: email,
            planType: planType,
            accountId: accountId,
            chatgptUserId: chatgptUserId,
            lastRefresh: lastRefresh,
            expiredGuess: expiredGuess,
            rawClaimKeys: claimKeys,
            accessToken: accessToken,
            refreshToken: refreshToken,
            idToken: idToken
        )
    }

    nonisolated static func authFileURL() -> URL {
        if let home = ProcessInfo.processInfo.environment["CODEX_HOME"], !home.isEmpty {
            return URL(fileURLWithPath: home).appendingPathComponent("auth.json")
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/auth.json")
    }

    nonisolated private static func parseDate(_ any: Any?) -> Date? {
        if let s = any as? String {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = iso.date(from: s) { return d }
            iso.formatOptions = [.withInternetDateTime]
            return iso.date(from: s)
        }
        if let n = any as? Double { return Date(timeIntervalSince1970: n) }
        return nil
    }

    nonisolated private static func authClaim(_ key: String, from claims: [String: Any]?) -> String? {
        guard let auth = claims?["https://api.openai.com/auth"] as? [String: Any] else { return nil }
        return nonEmpty(auth[key] as? String)
    }

    nonisolated private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}
