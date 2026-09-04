import Foundation

nonisolated struct ConversationRollupPayload: Sendable, Codable {
    /// v5: 配合 ScanState v9 清除曾被提前入账的 Claude 流式半成品。
    /// v6: Pi/OpenCode 统一费用解析规则改变，旧聚合结果必须全量重算。
    /// v7: 配合 ScanState v13（项目归属隐私分级），受保护目录项目改为字符串归组，旧归组必须全量重算。
    static let currentVersion = 7
    var version = Self.currentVersion
    var generationID = ""
    /// 写盘时记录的价格指纹，仅作诊断；加载不因指纹不一致丢弃（价格变化不自动重算）。
    var pricingFingerprint = ""
    var infos: [ConversationInfo] = []
    var buckets: [ConversationUsageBucket] = []
    var updatedAt = Date.distantPast
}

enum ConversationRollupCache {
    nonisolated private static let fileName = "conversation-rollup.json"
    nonisolated private static let bundleDirectory = "CCBar"

    nonisolated static func load() -> ConversationRollupPayload {
        let url = cacheFileURL()
        guard let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(ConversationRollupPayload.self, from: data),
              payload.version == ConversationRollupPayload.currentVersion else {
            return ConversationRollupPayload()
        }
        return payload
    }

    nonisolated static func save(_ payload: ConversationRollupPayload) throws {
        let url = cacheFileURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(payload).write(to: url, options: [.atomic])
    }

    nonisolated static func cacheFileURL() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return support
            .appendingPathComponent(bundleDirectory, isDirectory: true)
            .appendingPathComponent(fileName)
    }
}
