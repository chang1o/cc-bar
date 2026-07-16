import Foundation

nonisolated struct ConversationRollupPayload: Sendable, Codable {
    /// v5: 配合 ScanState v9 清除曾被提前入账的 Claude 流式半成品。
    static let currentVersion = 5
    var version = Self.currentVersion
    var generationID = ""
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
        let knownModels = Set(payload.buckets.map { $0.model })
        guard payload.pricingFingerprint == Pricing.fingerprint(knownModels: knownModels) else {
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
