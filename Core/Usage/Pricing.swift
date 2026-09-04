import Foundation
import CryptoKit

/// 模型价格（USD / 百万 token）。命中不到的模型 cost 计 0，token 仍记录。
nonisolated struct ModelPrice: Sendable {
    var input: Decimal
    var output: Decimal
    var cacheRead: Decimal
    var cacheCreation: Decimal
}

nonisolated enum Pricing {
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
        "gpt-5.6":           .init(input: 5,    output: 30,  cacheRead: 0.50,  cacheCreation: 0),
        "codex-mini-latest": .init(input: 1.50, output: 6,   cacheRead: 0.375, cacheCreation: 0)
        // codex-auto-review 内部 review，官方未公开计费；不入表 → cost=0，token 仍记录
    ]

    /// 归一化模型名：去 `openai/` 前缀；剥末尾 `-YYYY-MM-DD` 或 `-YYYYMMDD` 日期后缀；
    /// 兼容 Vertex AI 的 `@日期` 写法。
    static func normalize(model: String) -> String {
        var m = model
        if m.hasPrefix("openai/") {
            m.removeFirst("openai/".count)
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
    ///   - input/output/cacheRead/cacheCreation: 直接乘价。
    static func cost(
        model: String,
        input: Int,
        output: Int,
        cacheRead: Int,
        cacheCreation: Int
    ) -> Decimal {
        let key = normalize(model: model)
        guard let p = table[key] else { return 0 }
        let i = Decimal(input)     * p.input        / perMillion
        let o = Decimal(output)    * p.output       / perMillion
        let cr = Decimal(cacheRead) * p.cacheRead   / perMillion
        let cc = Decimal(cacheCreation) * p.cacheCreation / perMillion
        return i + o + cr + cc
    }

    static func hasPrice(model: String) -> Bool {
        table[normalize(model: model)] != nil
    }

    /// 价格表内容指纹（SHA-256，确定性，跨进程稳定）。
    /// 扫描状态 / 汇总缓存持久化它；表一变（新增模型、改价、修正数值）→ 指纹变 →
    /// 缓存自动失效并全量重扫重算历史桶，无需手动 bump 版本号，避免「改了价却忘了重算」。
    static let fingerprint: String = {
        let body = table.keys.sorted().map { key -> String in
            let p = table[key]!
            return "\(key):\(p.input)/\(p.output)/\(p.cacheRead)/\(p.cacheCreation)"
        }.joined(separator: ";")
        let digest = SHA256.hash(data: Data(body.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }()
}
