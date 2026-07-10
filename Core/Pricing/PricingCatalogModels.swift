import Foundation

/// 单个远端价格源（LiteLLM / models.dev）的内存态与磁盘态。
/// `rates` 的 key 是归一化后的模型名（`Pricing.normalize(model:)`），value 已换算成
/// 「USD / 百万 token」，与本地 `Pricing.table` 同单位，可直接比较、直接用于计价。
nonisolated struct PricingSourceState: Sendable, Codable {
    var etag: String?
    var fetchedAt: Date?
    var failedAt: Date?
    var rates: [String: ModelPrice] = [:]
}

/// `pricing-catalog.json` 的持久化结构。
nonisolated struct PricingCatalogCachePayload: Sendable, Codable {
    /// version 管结构兼容性；内容是否可信由各源自身的 etag/fetchedAt 判断，不需要额外指纹。
    static let currentVersion = 1

    var version: Int = PricingCatalogCachePayload.currentVersion
    var liteLLM: PricingSourceState = .init()
    var modelsDev: PricingSourceState = .init()
}

/// 解码远端 JSON 失败或结果为空时抛出，触发调用方「不覆盖旧缓存」的保护逻辑。
nonisolated enum PricingCatalogError: Error {
    case notAnObject
    case emptyFeed
}
