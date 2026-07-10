import Foundation

/// 解析 LiteLLM 的 `model_prices_and_context_window.json`。
///
/// 顶层是 `{modelKey: {...}}` 扁平字典，同一模型还会以 `azure/xxx`、`vertex_ai/xxx` 等供应商前缀
/// 重复出现——这些不是 cc-bar 场景会用到的名字（Codex / Claude Code CLI 上报的 model 字段不带这类前缀），
/// 只取不含 `/` 的裸键，并用 `litellm_provider` 白名单二次校验，双重过滤掉转售渠道。
/// 用 `JSONSerialization` 而非 `Decodable`：单条脏数据（字段缺失/类型不对）跳过即可，不拖垮整个 feed。
nonisolated enum LiteLLMPricingDecoder {
    nonisolated private static let allowedProviders: Set<String> = ["anthropic", "openai", "deepseek"]
    nonisolated private static let perMillion: Decimal = 1_000_000

    /// - Returns: key 为归一化后的模型名，value 已换算成 USD / 百万 token。
    /// - Throws: `PricingCatalogError.notAnObject` 顶层不是 JSON 对象；
    ///           `PricingCatalogError.emptyFeed` 解析后一条可用条目都没有。
    nonisolated static func decode(_ data: Data) throws -> [String: ModelPrice] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PricingCatalogError.notAnObject
        }

        var bareCandidates: [(key: String, price: ModelPrice)] = []
        for (rawKey, value) in root {
            guard !rawKey.contains("/"), let entry = value as? [String: Any] else { continue }
            guard let provider = entry["litellm_provider"] as? String, allowedProviders.contains(provider) else {
                continue
            }
            guard let price = parseRates(entry) else { continue }
            bareCandidates.append((rawKey, price))
        }

        let orderedCandidates = bareCandidates.sorted { $0.key < $1.key }
        var result: [String: ModelPrice] = [:]
        // 裸名（normalize 后等于自身）优先写入。
        for candidate in orderedCandidates where Pricing.normalize(model: candidate.key) == candidate.key {
            guard result[candidate.key] == nil else { continue }
            result[candidate.key] = candidate.price
        }
        // 日期后缀等变体只在裸名缺失时兜底填坑，避免多个快照互相覆盖出不确定的价格。
        for candidate in orderedCandidates {
            let normalized = Pricing.normalize(model: candidate.key)
            guard result[normalized] == nil else { continue }
            result[normalized] = candidate.price
        }

        guard !result.isEmpty else { throw PricingCatalogError.emptyFeed }
        return result
    }

    /// `input`/`output` 必须同时存在才纳入；`cacheRead`/`cacheCreation` 缺失按 0
    /// （不猜价格，与本地 `Pricing.table` 里 GPT-5 系 `cacheCreation: 0` 的既有约定一致）。
    nonisolated private static func parseRates(_ entry: [String: Any]) -> ModelPrice? {
        guard let input = decimal(entry["input_cost_per_token"]),
              let output = decimal(entry["output_cost_per_token"])
        else { return nil }
        let cacheRead = decimal(entry["cache_read_input_token_cost"]) ?? 0
        let cacheCreation = decimal(entry["cache_creation_input_token_cost"]) ?? 0
        return ModelPrice(
            input: input * perMillion,
            output: output * perMillion,
            cacheRead: cacheRead * perMillion,
            cacheCreation: cacheCreation * perMillion
        )
    }

    nonisolated private static func decimal(_ value: Any?) -> Decimal? {
        guard let number = value as? NSNumber else { return nil }
        return Decimal(number.doubleValue)
    }
}
