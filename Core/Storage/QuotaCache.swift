import Foundation

nonisolated struct QuotaCacheRecord: Sendable, Equatable, Codable {
    var snapshot: QuotaSnapshot
    var source: QuotaSnapshotSource
    var updatedAt: Date
}

nonisolated struct QuotaCachePayload: Sendable, Equatable, Codable {
    static let currentVersion = 3

    var version: Int = Self.currentVersion
    var providers: [QuotaApp: QuotaCacheRecord] = [:]
    /// 用户导入的 Codex 账号配额缓存,key = ImportedCodexAccount.id (= chatgpt_account_id)。
    /// 字段缺失时解码为 nil,旧缓存文件兼容。
    var importedCodex: [String: QuotaCacheRecord]?

    var codex: QuotaCacheRecord? {
        get { providers[.codex] }
        set { providers[.codex] = newValue }
    }

    var claude: QuotaCacheRecord? {
        get { providers[.claude] }
        set { providers[.claude] = newValue }
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case providers
        case codex
        case claude
        case importedCodex
    }

    init(
        version: Int = Self.currentVersion,
        providers: [QuotaApp: QuotaCacheRecord] = [:],
        importedCodex: [String: QuotaCacheRecord]? = nil
    ) {
        self.version = version
        self.providers = providers
        self.importedCodex = importedCodex
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedVersion = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        importedCodex = try container.decodeIfPresent(
            [String: QuotaCacheRecord].self,
            forKey: .importedCodex
        )

        if decodedVersion >= 2 {
            version = Self.currentVersion
            // 以 String 键解码后按 QuotaApp(rawValue:) 过滤，丢弃已删除的
            // provider（如旧版缓存中的 antigravity），避免整个缓存解码失败。
            let rawProviders = try container.decodeIfPresent(
                [String: QuotaCacheRecord].self,
                forKey: .providers
            ) ?? [:]
            providers = Dictionary(
                uniqueKeysWithValues: rawProviders.compactMap { key, record in
                    QuotaApp(rawValue: key).map { ($0, record) }
                }
            )
        } else {
            version = Self.currentVersion
            providers = [:]
            if let codex = try container.decodeIfPresent(QuotaCacheRecord.self, forKey: .codex) {
                providers[.codex] = codex
            }
            if let claude = try container.decodeIfPresent(QuotaCacheRecord.self, forKey: .claude) {
                providers[.claude] = claude
            }
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentVersion, forKey: .version)
        try container.encode(providers, forKey: .providers)
        try container.encodeIfPresent(importedCodex, forKey: .importedCodex)
    }
}

enum QuotaCache {
    nonisolated private static let fileName = "quota-cache.json"
    nonisolated private static let bundleDirectory = "CCBar"

    nonisolated static func load() -> QuotaCachePayload {
        let url = cacheFileURL()
        guard let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(QuotaCachePayload.self, from: data)
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
