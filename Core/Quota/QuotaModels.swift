import Foundation

enum QuotaApp: String, Sendable, Codable, CaseIterable, Hashable {
    case codex
    case claude
    case antigravity
}

struct QuotaProviderDescriptor: Sendable, Hashable, Identifiable {
    let app: QuotaApp
    let title: String
    let vendor: String
    let logoName: String
    let fallback: String
    let supportsLocalCost: Bool

    var id: QuotaApp { app }

    static let primaryProviders: [QuotaProviderDescriptor] = [
        QuotaProviderDescriptor(
            app: .codex,
            title: "Codex",
            vendor: "OpenAI",
            logoName: "codex",
            fallback: "C",
            supportsLocalCost: true
        ),
        QuotaProviderDescriptor(
            app: .claude,
            title: "Claude Code",
            vendor: "Anthropic",
            logoName: "claude",
            fallback: "K",
            supportsLocalCost: true
        ),
        QuotaProviderDescriptor(
            app: .antigravity,
            title: "Antigravity",
            vendor: "Google",
            logoName: "antigravity",
            fallback: "A",
            supportsLocalCost: false
        ),
    ]
}

enum QuotaSnapshotSource: String, Sendable, Codable {
    case api
    case local
    case cache
    case cliFallback

    var displayName: String {
        switch self {
        case .api: return "API"
        case .local: return "本机"
        case .cache: return "缓存"
        case .cliFallback: return "Claude CLI"
        }
    }
}

enum QuotaRefreshReason: Sendable {
    case periodic
    case userInitiated
}

struct QuotaRefreshState: Sendable, Equatable {
    var lastSuccessAt: Date?
    var lastAttemptAt: Date?
    var backoffUntil: Date?
    var lastError: String?
    var inFlight: Bool = false
    var source: QuotaSnapshotSource?
}

struct PrimaryQuotaState: Sendable, Equatable {
    var snapshot: QuotaSnapshot?
    var error: String?
    var source: QuotaSnapshotSource?
    var refresh = QuotaRefreshState()
}

struct AntigravityAccount: Sendable, Equatable {
    var email: String?
    var planType: String?
}

enum AntigravityAvailability: Sendable, Equatable {
    case notInstalled
    case installed
    case running
    case unavailable(String)
}

struct QuotaWindow: Sendable, Equatable, Codable {
    /// 0~100，已用百分比
    var usedPercent: Double
    /// 窗口重置时间
    var resetsAt: Date?
    /// 窗口长度（秒），可空
    var windowSeconds: Int?

    var remainingPercent: Double {
        max(0, min(100, 100 - usedPercent))
    }
}

struct QuotaSnapshot: Sendable, Equatable, Codable {
    var app: QuotaApp
    var fiveHour: QuotaWindow?
    var weekly: QuotaWindow?
    var weeklyOpus: QuotaWindow?      // 仅 Claude
    var weeklySonnet: QuotaWindow?    // 仅 Claude
    var geminiWindow: QuotaWindow?    // 仅 Antigravity，Gemini 5h 额度
    var geminiWeekly: QuotaWindow?   // 仅 Antigravity，Gemini 周额度
    var planType: String?
    var fetchedAt: Date
}

enum QuotaError: Error, CustomStringConvertible {
    case missingToken
    case http(Int, String)
    case transport(String)
    case decode(String)
    case tokenRefreshFailed(String)
    /// OAuth 服务端拒绝了 refresh_token(典型为 `invalid_grant`),
    /// 通常是 Claude Code CLI / Desktop / cc-switch 等其他客户端抢先刷新使旧 token 失效,
    /// 或用户主动退登 / 改密码。此时只能重新登录。
    case tokenRevoked

    var description: String {
        switch self {
        case .missingToken: return "missing access token"
        case .http(let code, let msg): return "http \(code): \(msg)"
        case .transport(let msg): return "transport: \(msg)"
        case .decode(let msg): return "decode: \(msg)"
        case .tokenRefreshFailed(let msg): return "token refresh failed: \(msg)"
        case .tokenRevoked:
            return "Claude 登录已失效,请在终端运行 claude 重新登录后再回来刷新"
        }
    }

    var httpStatusCode: Int? {
        if case .http(let code, _) = self { return code }
        return nil
    }

    var isRateLimited: Bool {
        httpStatusCode == 429
    }

    var isAuthFailure: Bool {
        httpStatusCode == 401 || httpStatusCode == 403
    }

    /// 是否为"需要用户重新登录"级别的失败。UI 可据此降级提示文案。
    var isAuthRevoked: Bool {
        if case .tokenRevoked = self { return true }
        return false
    }
}
