import Foundation

/// Every service cc-bar can monitor. Order is the display order everywhere
/// (menu bar, popover, HUD, stats): Codex always comes before Claude.
nonisolated enum Provider: String, CaseIterable, Codable, Sendable, Hashable {
    case codex
    case claude
    case kimi
    case glm
    case ollama

    var descriptor: ProviderDescriptor {
        ProviderDescriptor.all[self]!
    }

    var displayName: String { descriptor.displayName }
    var logoName: String { descriptor.logoName }
}

nonisolated enum QuotaWindowKind: String, Codable, Sendable, Hashable {
    case fiveHour
    case weekly
    case monthly
    case weeklyOpus
    case weeklySonnet
    case mcp
    /// Claude pay-as-you-go overage on top of the subscription: a monthly cap in currency.
    case extraUsage

    var shortLabel: String {
        switch self {
        case .fiveHour: return "5H"
        case .weekly: return "WK"
        case .monthly: return "MO"
        case .weeklyOpus: return "OPUS"
        case .weeklySonnet: return "SONNET"
        case .mcp: return "MCP"
        case .extraUsage: return "EXTRA"
        }
    }

    /// Window length when the API does not report one. Monthly windows are
    /// inferred from the reset date instead (see `QuotaPace`).
    var defaultSeconds: Int? {
        switch self {
        case .fiveHour: return 5 * 60 * 60
        case .weekly, .weeklyOpus, .weeklySonnet: return 7 * 24 * 60 * 60
        case .monthly, .mcp, .extraUsage: return nil
        }
    }

    var englishTitle: String {
        switch self {
        case .fiveHour: return "5-HOUR"
        case .weekly: return "WEEKLY"
        case .monthly: return "MONTHLY"
        case .weeklyOpus: return "WEEKLY OPUS"
        case .weeklySonnet: return "WEEKLY SONNET"
        case .mcp: return "MCP"
        case .extraUsage: return "EXTRA USAGE"
        }
    }

    var chineseTitle: String {
        switch self {
        case .fiveHour: return "五小时"
        case .weekly: return "周额度"
        case .monthly: return "月额度"
        case .weeklyOpus: return "周 Opus"
        case .weeklySonnet: return "周 Sonnet"
        case .mcp: return "MCP"
        case .extraUsage: return "超额用量"
        }
    }
}

/// Static per-provider facts. Anything a view or fetcher needs to branch on
/// lives here so the rest of the app never switches on `Provider` directly.
nonisolated struct ProviderDescriptor: Sendable {
    let id: Provider
    let displayName: String
    let vendor: String
    let logoName: String
    let fallbackGlyph: String
    let primaryKind: QuotaWindowKind
    let secondaryKind: QuotaWindowKind?
    let supportsCost: Bool
    let statusPageURL: URL?
    /// What ccpm writes into `ANTHROPIC_BASE_URL` for this provider.
    let defaultBaseURL: URL?
    /// Provider usage dashboard for the card action row; GLM resolves per account (see `MonitoredAccount.dashboardURL`).
    let dashboardURL: URL?
    /// Human-facing status page for the card action row.
    let statusPageWebURL: URL?

    static let all: [Provider: ProviderDescriptor] = [
        .codex: ProviderDescriptor(
            id: .codex,
            displayName: "Codex",
            vendor: "OpenAI",
            logoName: "codex",
            fallbackGlyph: "C",
            primaryKind: .fiveHour,
            secondaryKind: .weekly,
            supportsCost: true,
            statusPageURL: URL(string: "https://status.openai.com/api/v2/status.json"),
            defaultBaseURL: nil,
            dashboardURL: URL(string: "https://chatgpt.com/codex/settings/usage"),
            statusPageWebURL: URL(string: "https://status.openai.com")
        ),
        .claude: ProviderDescriptor(
            id: .claude,
            displayName: "Claude Code",
            vendor: "Anthropic",
            logoName: "claude",
            fallbackGlyph: "K",
            primaryKind: .fiveHour,
            secondaryKind: .weekly,
            supportsCost: true,
            statusPageURL: URL(string: "https://status.claude.com/api/v2/status.json"),
            defaultBaseURL: nil,
            dashboardURL: URL(string: "https://claude.ai/settings/usage"),
            statusPageWebURL: URL(string: "https://status.claude.com")
        ),
        .kimi: ProviderDescriptor(
            id: .kimi,
            displayName: "Kimi Code",
            vendor: "Moonshot",
            logoName: "kimi",
            fallbackGlyph: "M",
            primaryKind: .fiveHour,
            secondaryKind: .weekly,
            supportsCost: false,
            statusPageURL: nil,
            defaultBaseURL: URL(string: "https://api.kimi.com/coding/"),
            dashboardURL: URL(string: "https://www.kimi.com/code/console"),
            statusPageWebURL: nil
        ),
        .glm: ProviderDescriptor(
            id: .glm,
            displayName: "GLM Coding Plan",
            vendor: "Zhipu",
            logoName: "glm",
            fallbackGlyph: "G",
            primaryKind: .fiveHour,
            secondaryKind: .weekly,
            supportsCost: false,
            statusPageURL: nil,
            defaultBaseURL: URL(string: "https://open.bigmodel.cn/api/anthropic"),
            dashboardURL: nil,
            statusPageWebURL: nil
        ),
        .ollama: ProviderDescriptor(
            id: .ollama,
            displayName: "Ollama Cloud",
            vendor: "Ollama",
            logoName: "ollama",
            fallbackGlyph: "O",
            primaryKind: .monthly,
            secondaryKind: .weekly,
            supportsCost: false,
            statusPageURL: nil,
            defaultBaseURL: URL(string: "https://ollama.com"),
            dashboardURL: URL(string: "https://ollama.com/settings"),
            statusPageWebURL: nil
        )
    ]
}

extension MonitoredAccount {
    /// Usage dashboard for this account. GLM has two consoles: BigModel CN for
    /// `bigmodel.cn` base URLs, z.ai global otherwise.
    var dashboardURL: URL? {
        guard provider == .glm else { return descriptor.dashboardURL }
        var host: String?
        switch credential {
        case .apiKey(_, let baseURL), .ollamaCookie(_, let baseURL):
            host = baseURL.host?.lowercased()
        default:
            host = nil
        }
        if let host, host.contains("bigmodel.cn") {
            return URL(string: "https://bigmodel.cn/coding-plan/personal/usage")
        }
        return URL(string: "https://z.ai/manage-apikey/coding-plan/personal/my-plan")
    }
}
