import Foundation

/// Single entry point that turns an account's credential into a quota snapshot.
/// Token refresh happens here; the caller stores the returned credential so the
/// refreshed token is reused within the same refresh cycle.
nonisolated enum QuotaFetcher {
    struct Success: Sendable {
        var snapshot: QuotaSnapshot
        var source: QuotaSnapshotSource
        var credential: AccountCredential?
    }

    nonisolated static func fetch(account: MonitoredAccount) async -> Result<Success, QuotaError> {
        switch account.credential {
        case .codexOAuth(var codex, let writeBack):
            guard let token = nonEmpty(codex.accessToken) else { return .failure(.missingToken) }
            let refreshed = await CodexTokenRefresher.ensureFreshTokens(
                currentAccessToken: token,
                refreshToken: codex.refreshToken,
                idToken: codex.idToken,
                writeBack: writeBack
            )
            let activeToken: String
            switch refreshed {
            case .success(let tokens):
                activeToken = tokens.accessToken
                codex.accessToken = tokens.accessToken
                codex.refreshToken = nonEmpty(tokens.refreshToken)
                codex.idToken = tokens.idToken
                codex.expiredGuess = false
            case .failure(let error):
                return .failure(error)
            }
            let result = await CodexQuotaClient.fetch(accessToken: activeToken, accountId: codex.accountId)
            return result.map { Success(snapshot: $0, source: .api, credential: .codexOAuth(codex, writeBack: writeBack)) }

        case .claudeOAuth(var claude, let storage):
            guard claude.accessToken != nil else { return .failure(.missingToken) }
            let refreshed = await ClaudeTokenRefresher.ensureFreshAccessToken(account: &claude, storage: storage)
            let activeToken: String
            switch refreshed {
            case .success(let token):
                activeToken = token
            case .failure(let error):
                return .failure(error)
            }
            let result = await ClaudeQuotaClient.fetch(accessToken: activeToken)
            return result.map { Success(snapshot: $0, source: .api, credential: .claudeOAuth(claude, storage: storage)) }

        case .apiKey(let key, let baseURL):
            let result: Result<QuotaSnapshot, QuotaError>
            switch account.provider {
            case .kimi:
                result = await KimiQuotaClient.fetch(apiKey: key, baseURL: baseURL)
            case .glm:
                result = await GLMQuotaClient.fetch(apiKey: key, baseURL: baseURL)
            default:
                result = .failure(.decode("no api-key quota client for \(account.provider.rawValue)"))
            }
            return result.map { Success(snapshot: $0, source: .api, credential: nil) }

        case .ollamaCookie(let cookie, _):
            guard let cookie = nonEmpty(cookie) else { return .failure(.missingCookie) }
            let result = await OllamaCloudQuotaClient.fetch(cookieHeader: cookie)
            return result.map { Success(snapshot: $0, source: .api, credential: nil) }

        case .unavailable(let reason):
            return .failure(.transport(reason))
        }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}
