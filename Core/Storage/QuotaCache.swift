import Foundation

nonisolated struct QuotaCacheRecord: Sendable, Equatable, Codable {
    var snapshot: QuotaSnapshot
    var source: QuotaSnapshotSource
    var updatedAt: Date
    /// 仅远端账号型 Provider 使用；Cursor 绑定 JWT userID，防止账号切换串缓存。
    var accountID: String?

    init(
        snapshot: QuotaSnapshot,
        source: QuotaSnapshotSource,
        updatedAt: Date,
        accountID: String? = nil
    ) {
        self.snapshot = snapshot
        self.source = source
        self.updatedAt = updatedAt
        self.accountID = accountID
    }
}

nonisolated struct QuotaCachePayload: Sendable, Equatable, Codable {
    static let currentVersion = 4

    var version: Int = Self.currentVersion
    var providers: [QuotaApp: QuotaCacheRecord] = [:]
    /// 用户导入的 Codex 账号配额缓存,key = ImportedCodexAccount.id (= chatgpt_account_id)。
    /// 字段缺失时解码为 nil,旧缓存文件兼容。
    var importedCodex: [String: QuotaCacheRecord]?
    /// ccpm profile accounts, key = CCPMAccount.id (`<app>:ccpm:<profile>`). Mirrors of a
    /// primary account are written too so the ccpm statusline can read them.
    var ccpmAccounts: [String: QuotaCacheRecord]?

    var codex: QuotaCacheRecord? {
        get { providers[.codex] }
        set { providers[.codex] = newValue }
    }

    var claude: QuotaCacheRecord? {
        get { providers[.claude] }
        set { providers[.claude] = newValue }
    }

    var cursor: QuotaCacheRecord? {
        get { providers[.cursor] }
        set { providers[.cursor] = newValue }
    }

    var antigravity: QuotaCacheRecord? {
        get { providers[.antigravity] }
        set { providers[.antigravity] = newValue }
    }

    var commandCode: QuotaCacheRecord? {
        get { providers[.commandCode] }
        set { providers[.commandCode] = newValue }
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case providers
        case codex
        case claude
        case importedCodex
        case ccpmAccounts
    }

    init(
        version: Int = Self.currentVersion,
        providers: [QuotaApp: QuotaCacheRecord] = [:],
        importedCodex: [String: QuotaCacheRecord]? = nil,
        ccpmAccounts: [String: QuotaCacheRecord]? = nil
    ) {
        self.version = version
        self.providers = providers
        self.importedCodex = importedCodex
        self.ccpmAccounts = ccpmAccounts
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedVersion = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        importedCodex = try container.decodeIfPresent(
            [String: QuotaCacheRecord].self,
            forKey: .importedCodex
        )
        // Records of apps unknown to this build are dropped instead of failing the whole file.
        ccpmAccounts = try container.decodeIfPresent(
            [String: QuotaCacheRecord].self,
            forKey: .ccpmAccounts
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
        // providers 的 Key 是 enum，直接编码会退化成 JSON array（Swift 只对 String / Int /
        // CodingKeyRepresentable 键产出 object），而 decode 端按 [String: QuotaCacheRecord]
        // 读取，两端不对称会让写入的缓存永远解不回来（load() 的 try? 会把错误吞成空 payload，
        // 表现为每次重启额度快照全丢）。显式转成 String 键保持对称。
        try container.encode(
            Dictionary(uniqueKeysWithValues: providers.map { ($0.key.rawValue, $0.value) }),
            forKey: .providers
        )
        try container.encodeIfPresent(importedCodex, forKey: .importedCodex)
        try container.encodeIfPresent(ccpmAccounts, forKey: .ccpmAccounts)
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
