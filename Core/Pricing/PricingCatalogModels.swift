import Foundation

/// 价格目录与缓存指纹的最小查价身份。model 在初始化时统一归一化。
nonisolated struct PricingUsageKey: Sendable, Hashable {
    let app: UsageApp
    let model: String
    let speed: UsageSpeed

    init(app: UsageApp, model: String, speed: UsageSpeed) {
        self.app = app
        self.model = Pricing.normalize(model: model)
        self.speed = speed
    }

    var persistedKey: String {
        "\(app.rawValue)|\(speed.rawValue)|\(model)"
    }
}

/// 单次远端解码结果。Standard 与两种 App 的 Fast 必须分开保存，不能跨档位或跨 App 兜底。
nonisolated struct DecodedPricingRates: Sendable, Equatable {
    var standard: [String: ModelPrice] = [:]
    var codexFast: [String: ModelPrice] = [:]
    var claudeFast: [String: ModelPrice] = [:]
}

/// 单个远端价格源（LiteLLM / models.dev）的内存态与磁盘态。
/// 三份 rates 的 key 都是归一化后的模型名（`Pricing.normalize(model:)`），value 已换算成
/// 「USD / 百万 token」，与本地 `Pricing` 同单位，可直接比较、直接用于计价。
nonisolated struct PricingSourceState: Sendable, Codable {
    var etag: String?
    var fetchedAt: Date?
    var failedAt: Date?
    var standardRates: [String: ModelPrice] = [:]
    /// Fast 价格采用 last-known 合并语义：上游移除已下线型号时仍保留历史日志计价能力。
    var codexFastRates: [String: ModelPrice] = [:]
    var claudeFastRates: [String: ModelPrice] = [:]
}

/// `pricing-catalog.json` 的持久化结构。
nonisolated struct PricingCatalogCachePayload: Sendable, Codable {
    /// version 管结构兼容性；内容是否可信由各源自身的 etag/fetchedAt 判断，不需要额外指纹。
    static let currentVersion = 2

    var version: Int = PricingCatalogCachePayload.currentVersion
    var liteLLM: PricingSourceState = .init()
    var modelsDev: PricingSourceState = .init()
    /// 缺价触发刷新的持久化冷却，key 为 `app|speed|normalizedModel`。
    var missingRefreshAttempts: [String: Date] = [:]
}

/// 解码远端 JSON 失败或结果为空时抛出，触发调用方「不覆盖旧缓存」的保护逻辑。
nonisolated enum PricingCatalogError: Error {
    case notAnObject
    case emptyFeed
}
