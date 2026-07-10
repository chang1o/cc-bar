import Foundation
import CryptoKit

/// 模型价格（USD / 百万 token）。命中不到的模型 cost 计 0，token 仍记录。
struct ModelPrice: Sendable {
    var input: Decimal
    var output: Decimal
    var cacheRead: Decimal
    var cacheCreation: Decimal
}

/// 同一模型按单次请求完整输入量切换的上下文阶梯价。
/// `shortContext` / `longContext` 均为完整费率，避免值类型递归引用。
private struct ContextPriceTiers: Sendable {
    let longContextThreshold: Int
    let shortContext: ModelPrice
    let longContext: ModelPrice

    func rates(for inputTotal: Int) -> ModelPrice {
        inputTotal > longContextThreshold ? longContext : shortContext
    }
}

/// 限时覆盖价：某模型从 `from` 这天（UTC 0 点）起改用 `price`，用于极少数「同一模型中途涨价/降价」
/// 的场景（如 Sonnet 5）。绝大多数模型价格固定，不需要出现在这张表里。
private struct PricedPeriod: Sendable {
    let from: Date
    let price: ModelPrice
}

enum Pricing {
    /// 价格表与 cc-switch `seed_model_pricing` / CodexBar `CostUsagePricing` 对齐（2026 上半年价位）。
    /// 命中不到时返回 nil。键为归一化后的模型名（剥 `openai/` 前缀和末尾 `-YYYYMMDD` / `-YYYY-MM-DD` 日期段）。
    static let table: [String: ModelPrice] = [
        // —— Claude 4.x 系（input 已不含 cache_read）——
        "claude-fable-5":    .init(input: 10,  output: 50,  cacheRead: 1.00, cacheCreation: 12.50),
        "claude-opus-4-8":   .init(input: 5,   output: 25,  cacheRead: 0.50, cacheCreation: 6.25),
        "claude-opus-4-7":   .init(input: 5,   output: 25,  cacheRead: 0.50, cacheCreation: 6.25),
        "claude-opus-4-6":   .init(input: 5,   output: 25,  cacheRead: 0.50, cacheCreation: 6.25),
        "claude-opus-4-5":   .init(input: 5,   output: 25,  cacheRead: 0.50, cacheCreation: 6.25),
        "claude-opus-4-1":   .init(input: 15,  output: 75,  cacheRead: 1.50, cacheCreation: 18.75),
        "claude-opus-4":     .init(input: 15,  output: 75,  cacheRead: 1.50, cacheCreation: 18.75),
        // Sonnet 5 是当前生效价（2026-09-01 起的新价见下方 timedOverrides）。
        "claude-sonnet-5":   .init(input: 2,   output: 10,  cacheRead: 0.20, cacheCreation: 2.50),
        "claude-sonnet-4-7": .init(input: 3,   output: 15,  cacheRead: 0.30, cacheCreation: 3.75),
        "claude-sonnet-4-6": .init(input: 3,   output: 15,  cacheRead: 0.30, cacheCreation: 3.75),
        "claude-sonnet-4-5": .init(input: 3,   output: 15,  cacheRead: 0.30, cacheCreation: 3.75),
        "claude-sonnet-4":   .init(input: 3,   output: 15,  cacheRead: 0.30, cacheCreation: 3.75),
        "claude-haiku-4-5":  .init(input: 1,   output: 5,   cacheRead: 0.10, cacheCreation: 1.25),
        "claude-haiku-4":    .init(input: 0.8, output: 4,   cacheRead: 0.08, cacheCreation: 1.0),

        // —— Codex / GPT-5 系（input 含 cache_read，调用侧已扣 billable）。
        // 注：实际 5.5 在 >272k context 有阶梯价；本表采用 cc-switch 一致的「单档」价。
        "gpt-5":             .init(input: 1.25, output: 10,  cacheRead: 0.125, cacheCreation: 0),
        "gpt-5-mini":        .init(input: 0.25, output: 2,   cacheRead: 0.025, cacheCreation: 0),
        "gpt-5-nano":        .init(input: 0.05, output: 0.40, cacheRead: 0.005, cacheCreation: 0),
        "gpt-5-codex":       .init(input: 1.25, output: 10,  cacheRead: 0.125, cacheCreation: 0),
        "gpt-5.1":           .init(input: 1.25, output: 10,  cacheRead: 0.125, cacheCreation: 0),
        "gpt-5.1-codex":     .init(input: 1.25, output: 10,  cacheRead: 0.125, cacheCreation: 0),
        "gpt-5.2":           .init(input: 1.25, output: 10,  cacheRead: 0.125, cacheCreation: 0),
        "gpt-5.3":           .init(input: 1.25, output: 10,  cacheRead: 0.125, cacheCreation: 0),
        "gpt-5.4":           .init(input: 2.50, output: 15,  cacheRead: 0.25,  cacheCreation: 0),
        "gpt-5.4-codex":     .init(input: 2.50, output: 15,  cacheRead: 0.25,  cacheCreation: 0),
        "gpt-5.5":           .init(input: 5,    output: 30,  cacheRead: 0.50,  cacheCreation: 0),
        "gpt-5.5-codex":     .init(input: 5,    output: 30,  cacheRead: 0.50,  cacheCreation: 0),
        "gpt-5.5-pro":       .init(input: 5,    output: 30,  cacheRead: 0.50,  cacheCreation: 0),
        "codex-mini-latest": .init(input: 1.50, output: 6,   cacheRead: 0.375, cacheCreation: 0),

        // —— DeepSeek 系列（与 cc-switch seed_model_pricing 对齐）——
        // 缓存语义：通过 Anthropic 兼容端点使用时 input 不含 cache_read，直接乘价。
        // V4 系列官方 CNY 按 1 USD ≈ 7.14 折算。
        "deepseek-v4-pro":    .init(input: 0.435, output: 0.87,  cacheRead: 0.003625, cacheCreation: 0),
        "deepseek-v4-flash":  .init(input: 0.14,  output: 0.28,  cacheRead: 0.0028,   cacheCreation: 0),
        "deepseek-v3.2":      .init(input: 0.28,  output: 0.42,  cacheRead: 0.028,    cacheCreation: 0),
        "deepseek-v3.1":      .init(input: 0.55,  output: 1.67,  cacheRead: 0.055,    cacheCreation: 0),
        "deepseek-v3":        .init(input: 0.28,  output: 1.11,  cacheRead: 0.028,    cacheCreation: 0),
        "deepseek-chat":      .init(input: 0.27,  output: 1.10,  cacheRead: 0.07,     cacheCreation: 0),
        "deepseek-reasoner":  .init(input: 0.55,  output: 2.19,  cacheRead: 0.14,     cacheCreation: 0),
        // codex-auto-review 内部 review，官方未公开计费；不入表 → cost=0，token 仍记录
    ]

    /// OpenAI Standard API 的 GPT-5.6 上下文阶梯价（USD / 百万 token）。
    /// 完整输入严格超过 272K 时，该次请求的输入、缓存读写和输出全部使用长上下文费率。
    /// `gpt-5.6` 是 Sol 的别名；Pro 是 reasoning.mode，不是独立 model slug。
    private static let contextPriceTiers: [String: ContextPriceTiers] = [
        "gpt-5.6": .init(
            longContextThreshold: 272_000,
            shortContext: .init(input: 5, output: 30, cacheRead: 0.50, cacheCreation: 6.25),
            longContext: .init(input: 10, output: 45, cacheRead: 1, cacheCreation: 12.5)
        ),
        "gpt-5.6-sol": .init(
            longContextThreshold: 272_000,
            shortContext: .init(input: 5, output: 30, cacheRead: 0.50, cacheCreation: 6.25),
            longContext: .init(input: 10, output: 45, cacheRead: 1, cacheCreation: 12.5)
        ),
        "gpt-5.6-terra": .init(
            longContextThreshold: 272_000,
            shortContext: .init(input: 2.5, output: 15, cacheRead: 0.25, cacheCreation: 3.125),
            longContext: .init(input: 5, output: 22.5, cacheRead: 0.5, cacheCreation: 6.25)
        ),
        "gpt-5.6-luna": .init(
            longContextThreshold: 272_000,
            shortContext: .init(input: 1, output: 6, cacheRead: 0.1, cacheCreation: 1.25),
            longContext: .init(input: 2, output: 9, cacheRead: 0.2, cacheCreation: 2.5)
        )
    ]

    /// 少数模型中途涨价/降价的时间点覆盖；不在这里出现的模型永远用 `table` 里的固定价。
    /// 键为归一化后的模型名，每条按 `from` 升序排列；只要用量记录的日期 ≥ `from` 就换成对应新价，
    /// 取满足条件里最晚的一档（早于所有 `from` 时退回 `table` 的基准价）。
    private static let timedOverrides: [String: [PricedPeriod]] = [
        "claude-sonnet-5": [
            PricedPeriod(from: utcDate(2026, 9, 1), price: .init(input: 3, output: 15, cacheRead: 0.30, cacheCreation: 3.75))
        ]
    ]

    private static func utcDate(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    /// 取某模型在 `date` 这天应使用的价格：`table` 里的基准价，按 `timedOverrides` 就近覆盖。
    private static func price(for key: String, at date: Date, inputTotal: Int) -> ModelPrice? {
        if let tiers = contextPriceTiers[key] {
            return tiers.rates(for: inputTotal)
        }
        guard let base = table[key] else { return nil }
        guard let overrides = timedOverrides[key] else { return base }
        var chosen = base
        for period in overrides where period.from <= date {
            chosen = period.price
        }
        return chosen
    }

    /// 归一化模型名：去 `openai/` 前缀；剥末尾 `-YYYY-MM-DD` 或 `-YYYYMMDD` 日期后缀；
    /// 兼容 Vertex AI 的 `@日期` 写法。
    static func normalize(model: String) -> String {
        var m = model
        if m.hasPrefix("openai/") {
            m.removeFirst("openai/".count)
        }
        if m.hasPrefix("deepseek/") {
            m.removeFirst("deepseek/".count)
        }
        // Vertex 风格：`name@YYYYMMDD`
        if let at = m.firstIndex(of: "@") {
            m = String(m[m.startIndex..<at])
        }
        // Anthropic 风格：`-YYYYMMDD` 或 `-YYYY-MM-DD`
        let patterns = [#"-\d{4}-\d{2}-\d{2}$"#, #"-\d{8}$"#]
        for pat in patterns {
            if let range = m.range(of: pat, options: .regularExpression) {
                m.removeSubrange(range)
                break
            }
        }
        return m.lowercased()
    }

    private static let perMillion: Decimal = 1_000_000

    /// 计算单次调用花费。
    /// - Parameters:
    ///   - app: 用于隐含的 cache_read 语义；Codex 含、Claude 不含（调用方传 input 时已自处理）。
    ///   - at: 该条用量记录实际发生的时间，仅在模型存在 `timedOverrides` 时才会影响取价（如 Sonnet 5）。
    ///   - input/output/cacheRead/cacheCreation: 已拆分的四类 token，分别乘对应费率。
    ///   - inputTotal: 该请求完整输入 token；GPT-5.6 用它判断长上下文，缺省时由前三类输入相加。
    static func cost(
        model: String,
        input: Int,
        output: Int,
        cacheRead: Int,
        cacheCreation: Int,
        at date: Date,
        inputTotal: Int? = nil
    ) -> Decimal {
        let key = normalize(model: model)
        let fullInput = max(0, inputTotal ?? (input + cacheRead + cacheCreation))
        guard let p = price(for: key, at: date, inputTotal: fullInput) else { return 0 }
        let i = Decimal(input)     * p.input        / perMillion
        let o = Decimal(output)    * p.output       / perMillion
        let cr = Decimal(cacheRead) * p.cacheRead   / perMillion
        let cc = Decimal(cacheCreation) * p.cacheCreation / perMillion
        return i + o + cr + cc
    }

    static func hasPrice(model: String) -> Bool {
        let key = normalize(model: model)
        return table[key] != nil || contextPriceTiers[key] != nil
    }

    /// 价格表内容指纹（SHA-256，确定性，跨进程稳定）。
    /// 扫描状态 / 汇总缓存持久化它；表一变（新增模型、改价、修正数值、调整限时覆盖）→ 指纹变 →
    /// 缓存自动失效并全量重扫重算历史桶，无需手动 bump 版本号，避免「改了价却忘了重算」。
    static let fingerprint: String = {
        let baseBody = table.keys.sorted().map { key -> String in
            let p = table[key]!
            return "\(key):\(p.input)/\(p.output)/\(p.cacheRead)/\(p.cacheCreation)"
        }.joined(separator: ";")
        let tierBody = contextPriceTiers.keys.sorted().map { key -> String in
            let tiers = contextPriceTiers[key]!
            let short = tiers.shortContext
            let long = tiers.longContext
            return "\(key):\(tiers.longContextThreshold):\(short.input)/\(short.output)/\(short.cacheRead)/\(short.cacheCreation):\(long.input)/\(long.output)/\(long.cacheRead)/\(long.cacheCreation)"
        }.joined(separator: ";")
        let overrideBody = timedOverrides.keys.sorted().map { key -> String in
            let parts = timedOverrides[key]!.sorted { $0.from < $1.from }.map { period -> String in
                let p = period.price
                return "\(period.from.timeIntervalSince1970)=\(p.input)/\(p.output)/\(p.cacheRead)/\(p.cacheCreation)"
            }.joined(separator: ",")
            return "\(key)@\(parts)"
        }.joined(separator: ";")
        let digest = SHA256.hash(data: Data("\(baseBody)|\(tierBody)|\(overrideBody)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }()
}
