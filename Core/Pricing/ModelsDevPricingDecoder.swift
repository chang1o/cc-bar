import Foundation

/// 解析 models.dev 的 `api.json`。
///
/// 顶层结构是 `{providerId: {models: {modelId: {cost: {...}}}}}`。同一 modelId 会在几十个转售商
/// provider 下重复出现且价格未必相同（如某些 Claude 型号在 venice/azure/aihubmix 等渠道都有条目），
/// 必须限定只取官方 provider，不能随便取第一个匹配。用 `JSONSerialization` 而非 `Decodable`，
/// 单条脏数据跳过即可，不拖垮整个 feed。
nonisolated enum ModelsDevPricingDecoder {
    /// 同名模型跨官方 provider 出现时，保持这个显式优先级；不要使用 Set 遍历顺序。
    nonisolated private static let allowedProviders = ["anthropic", "openai", "deepseek"]

    nonisolated private struct Candidate {
        let key: String
        let providerPriority: Int
        let price: ModelPrice
    }

    /// - Returns: Standard / Fast 两套归一化价格（models.dev 原生单位为 USD / 百万 token）。
    /// - Throws: `PricingCatalogError.notAnObject` 顶层不是 JSON 对象；
    ///           `PricingCatalogError.emptyFeed` 解析后一条可用条目都没有。
    nonisolated static func decode(_ data: Data) throws -> DecodedPricingRates {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PricingCatalogError.notAnObject
        }

        var standardCandidates: [Candidate] = []
        var codexFastCandidates: [Candidate] = []
        var claudeFastCandidates: [Candidate] = []
        for (providerPriority, providerId) in allowedProviders.enumerated() {
            guard let providerEntry = root[providerId] as? [String: Any],
                  let models = providerEntry["models"] as? [String: Any]
            else { continue }
            for (modelId, value) in models {
                guard let entry = value as? [String: Any] else { continue }
                if let cost = entry["cost"] as? [String: Any],
                   let price = parseRates(cost) {
                    standardCandidates.append(.init(
                        key: modelId,
                        providerPriority: providerPriority,
                        price: price
                    ))
                }
                if let experimental = entry["experimental"] as? [String: Any],
                   let modes = experimental["modes"] as? [String: Any],
                   let fast = modes["fast"] as? [String: Any],
                   let cost = fast["cost"] as? [String: Any],
                   let price = parseRates(cost) {
                    let candidate = Candidate(
                        key: modelId,
                        providerPriority: providerPriority,
                        price: price
                    )
                    switch providerId {
                    case "openai": codexFastCandidates.append(candidate)
                    case "anthropic": claudeFastCandidates.append(candidate)
                    default: break
                    }
                }
            }
        }

        let standard = resolve(standardCandidates)
        let codexFast = resolve(codexFastCandidates)
        let claudeFast = resolve(claudeFastCandidates)
        guard !standard.isEmpty else { throw PricingCatalogError.emptyFeed }
        return DecodedPricingRates(
            standard: standard,
            codexFast: codexFast,
            claudeFast: claudeFast
        )
    }

    private static func resolve(_ candidates: [Candidate]) -> [String: ModelPrice] {
        let orderedCandidates = candidates.sorted {
            $0.key == $1.key ? $0.providerPriority < $1.providerPriority : $0.key < $1.key
        }
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

        return result
    }

    /// `input`/`output` 必须同时存在才纳入；`cache_read`/`cache_write` 缺失按 0（不猜价格）。
    nonisolated private static func parseRates(_ cost: [String: Any]) -> ModelPrice? {
        guard let input = decimal(cost["input"]), let output = decimal(cost["output"]) else { return nil }
        let cacheRead = decimal(cost["cache_read"]) ?? 0
        let cacheCreation = decimal(cost["cache_write"]) ?? 0
        return ModelPrice(input: input, output: output, cacheRead: cacheRead, cacheCreation: cacheCreation)
    }

    nonisolated private static func decimal(_ value: Any?) -> Decimal? {
        guard let number = value as? NSNumber else { return nil }
        return Decimal(number.doubleValue)
    }
}
