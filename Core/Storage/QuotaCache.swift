import Foundation

struct QuotaCacheRecord: Sendable, Equatable, Codable {
    var snapshot: QuotaSnapshot
    var source: QuotaSnapshotSource
    var updatedAt: Date
}

struct QuotaCachePayload: Sendable, Equatable, Codable {
    var version: Int = 1
    var codex: QuotaCacheRecord?
    var claude: QuotaCacheRecord?
    /// 用户导入的 Codex 账号配额缓存,key = ImportedCodexAccount.id (= chatgpt_account_id)。
    /// 字段缺失时解码为 nil,旧缓存文件兼容。
    var importedCodex: [String: QuotaCacheRecord]?
    var ccpmCodex: [String: QuotaCacheRecord]?
    var ccpmClaude: [String: QuotaCacheRecord]?
}

enum QuotaCache {
    nonisolated private static let fileName = "quota-cache.json"
    nonisolated private static let bundleDirectory = "CCBar"

    nonisolated static func load() -> QuotaCachePayload {
        let url = cacheFileURL()
        guard let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(QuotaCachePayload.self, from: data),
              payload.version == 1
        else {
            return QuotaCachePayload()
        }
        return payload
    }

    nonisolated static func save(_ payload: QuotaCachePayload) throws {
        let url = cacheFileURL()
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(payload)
        try data.write(to: url, options: [.atomic])
    }

    nonisolated static func cacheFileURL() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return support
            .appendingPathComponent(bundleDirectory, isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
    }
}
