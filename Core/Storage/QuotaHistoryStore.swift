import CryptoKit
import Foundation

nonisolated enum QuotaHistoryAccountKind: String, Sendable, Codable {
    case codexPrimary
    case codexImported
    case claudePrimary
}

nonisolated struct QuotaHistorySample: Sendable, Equatable, Codable {
    var accountKey: String
    var app: QuotaApp
    var kind: QuotaHistoryAccountKind
    var sampledAt: Date
    var limitID: String
    var limitKind: QuotaLimitKind
    var remainingPercent: Int
    var resetsAt: Date?
}

nonisolated struct QuotaChangeEvent: Sendable, Equatable, Codable, Identifiable {
    var id: String
    var accountKey: String
    var app: QuotaApp
    var kind: QuotaHistoryAccountKind
    var sampledAt: Date
    var limitID: String
    var limitKind: QuotaLimitKind
    var beforeRemainingPercent: Int
    var afterRemainingPercent: Int
    var deltaPercent: Int
    var resetsAt: Date?
}

nonisolated struct QuotaHistoryPayload: Sendable, Equatable, Codable {
    static let currentVersion = 3

    var version: Int = Self.currentVersion
    var dayStart: Date = QuotaHistoryStore.todayStart()
    /// key = `seriesKey(accountKey:limitKind:)`，每个账号的 5H / 每周窗口各一个最新样本。
    var lastSamples: [String: QuotaHistorySample] = [:]
    var events: [QuotaChangeEvent] = []
}

enum QuotaHistoryAccountKey {
    nonisolated static func codexPrimary(accountId: String?) -> String {
        if let id = nonEmpty(accountId) {
            return "codex:primary:\(id)"
        }
        return "codex:primary"
    }

    nonisolated static func codexImported(id: String) -> String {
        "codex:imported:\(id)"
    }

    nonisolated static func claudePrimary(email: String?) -> String {
        guard let email = nonEmpty(email)?.lowercased() else {
            return "claude:primary"
        }
        let digest = SHA256.hash(data: Data(email.utf8))
        return "claude:primary:\(digest.map { String(format: "%02x", $0) }.joined())"
    }

    nonisolated private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}

enum QuotaHistoryStore {
    nonisolated private static let fileName = "quota-history-today.json"
    nonisolated private static let bundleDirectory = "CCBar"
    /// 保留天数：覆盖完整滚动周窗口（7 天）+ 上一轮周窗口对比 + 5H 重叠缓冲。
    /// 老版本事件只存在「当天」，升级后只能从当天开始积累，不回补历史。
    nonisolated private static let retentionDays = 15

    nonisolated static func seriesKey(accountKey: String, limitKind: QuotaLimitKind) -> String {
        "\(accountKey)|\(limitKind.rawValue)"
    }

    nonisolated static func load(now: Date = Date()) -> QuotaHistoryPayload {
        let url = fileURL()
        guard let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(QuotaHistoryPayload.self, from: data)
        else {
            return QuotaHistoryPayload(dayStart: todayStart(now: now))
        }
        switch payload.version {
        case 2:
            // 老格式：lastSamples key 只有账号维度；按样本里的 limitKind 扩为窗口系列。
            return prune(migratingV2(payload), now: now)
        case QuotaHistoryPayload.currentVersion:
            return prune(payload, now: now)
        default:
            return QuotaHistoryPayload(dayStart: todayStart(now: now))
        }
    }

    nonisolated static func save(_ payload: QuotaHistoryPayload) throws {
        let url = fileURL()
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(payload)
        try data.write(to: url, options: [.atomic])
    }

    /// v2 → v3：每个账号的 lastSamples 从「主额度唯一」扩展成按窗口系列（5H / 每周）分别存储。
    nonisolated private static func migratingV2(_ payload: QuotaHistoryPayload) -> QuotaHistoryPayload {
        var next = payload
        next.version = QuotaHistoryPayload.currentVersion
        var migrated: [String: QuotaHistorySample] = [:]
        for (key, sample) in next.lastSamples {
            migrated[seriesKey(accountKey: key, limitKind: sample.limitKind)] = sample
        }
        next.lastSamples = migrated
        return next
    }

    /// 旧版 Claude 主账号恒用 `claude:primary`，历史无法再拆分。
    /// 首次取得当前邮箱后将这批当日数据一次性归入当前账号。
    nonisolated static func migratingLegacyClaudeAccountKey(
        _ payload: QuotaHistoryPayload,
        to accountKey: String
    ) -> QuotaHistoryPayload {
        let legacyKey = "claude:primary"
        guard accountKey != legacyKey else { return payload }
        var next = payload
        // seriesKey = "\(accountKey)|\(kind)"；仅迁移恰好是旧常量键（或其后缀系列）的条目，
        // 已哈希账号键形如 "claude:primary:hash|fiveHour"，前缀为 "claude:primary:"，不会误匹配。
        next.lastSamples = next.lastSamples.reduce(into: [:]) { result, entry in
            guard !entry.value.accountKey.hasPrefix(legacyKey + ":") else {
                result[entry.key] = entry.value
                return
            }
            var sample = entry.value
            sample.accountKey = accountKey
            result[seriesKey(accountKey: accountKey, limitKind: sample.limitKind)] = sample
        }
        // 事件只有 v2 常量键 "claude:primary" 需要迁移；v3 起事件会落已哈希键，不能误迁。
        for index in next.events.indices where next.events[index].accountKey == legacyKey {
            next.events[index].accountKey = accountKey
        }
        return next
    }

    /// 同时记录快照中的标准 5 小时 / 每周主次窗口，每个窗口独立成系列
    /// （各自的最新样本、变动事件与窗口边界互不影响）。
    nonisolated static func record(
        payload: QuotaHistoryPayload,
        accountKey: String,
        app: QuotaApp,
        kind: QuotaHistoryAccountKind,
        snapshot: QuotaSnapshot,
        sampledAt: Date
    ) -> QuotaHistoryPayload {
        let limits = [snapshot.primaryLimit, snapshot.secondaryLimit]
            .compactMap { $0 }
            .filter { $0.kind == .fiveHour || $0.kind == .weekly }
        guard !limits.isEmpty else {
            return prune(payload, now: sampledAt)
        }

        var next = prune(payload, now: sampledAt)
        for limit in limits {
            next = recordingSeries(
                payload: next,
                accountKey: accountKey,
                app: app,
                kind: kind,
                limit: limit,
                sampledAt: sampledAt
            )
        }
        return next
    }

    nonisolated private static func recordingSeries(
        payload: QuotaHistoryPayload,
        accountKey: String,
        app: QuotaApp,
        kind: QuotaHistoryAccountKind,
        limit: QuotaLimit,
        sampledAt: Date
    ) -> QuotaHistoryPayload {
        let series = seriesKey(accountKey: accountKey, limitKind: limit.kind)
        var next = payload
        let remaining = roundedPercent(limit.window.remainingPercent)
        let previous = next.lastSamples[series]
        let sameLimitPrevious = previous.flatMap {
            $0.limitID == limit.id && $0.limitKind == limit.kind ? $0 : nil
        }

        // 服务端把该窗口重置为不同类型 / 新 ID 时不是同一条曲线，清掉该系列
        // 的旧基准与事件，从新窗口重新采样，避免制造虚假涨跌。
        if let previous,
           previous.limitID != limit.id || previous.limitKind != limit.kind
        {
            next.events.removeAll { $0.accountKey == accountKey && $0.limitKind == limit.kind }
            next.lastSamples.removeValue(forKey: series)
        }

        next.lastSamples[series] = QuotaHistorySample(
            accountKey: accountKey,
            app: app,
            kind: kind,
            sampledAt: sampledAt,
            limitID: limit.id,
            limitKind: limit.kind,
            remainingPercent: remaining,
            resetsAt: limit.window.resetsAt
        )

        guard let previous = sameLimitPrevious,
              previous.remainingPercent != remaining
        else {
            return next
        }

        let delta = remaining - previous.remainingPercent
        next.events.append(QuotaChangeEvent(
            id: eventId(
                accountKey: accountKey,
                limitID: limit.id,
                sampledAt: sampledAt,
                before: previous.remainingPercent,
                after: remaining
            ),
            accountKey: accountKey,
            app: app,
            kind: kind,
            sampledAt: sampledAt,
            limitID: limit.id,
            limitKind: limit.kind,
            beforeRemainingPercent: previous.remainingPercent,
            afterRemainingPercent: remaining,
            deltaPercent: delta,
            resetsAt: limit.window.resetsAt
        ))
        return next
    }

    nonisolated static func todayStart(now: Date = Date()) -> Date {
        Calendar.current.startOfDay(for: now)
    }

    nonisolated static func fileURL() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return support
            .appendingPathComponent(bundleDirectory, isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
    }

    /// 只保留最近 `retentionDays` 个自然日（含今天）的数据；更老的样本和事件清理，
    /// 保证完整的滚动周窗口（7 天）与上一轮周窗口对比始终可用。
    nonisolated private static func prune(_ payload: QuotaHistoryPayload, now: Date) -> QuotaHistoryPayload {
        let start = todayStart(now: now)
        let cutoff = Calendar.current.date(
            byAdding: .day,
            value: -(Self.retentionDays - 1),
            to: start
        ) ?? start
        var next = payload
        next.dayStart = start
        next.events = next.events.filter { $0.sampledAt >= cutoff }
        next.lastSamples = next.lastSamples.filter { $0.value.sampledAt >= cutoff }
        return next
    }

    nonisolated private static func roundedPercent(_ value: Double) -> Int {
        max(0, min(100, Int(value.rounded())))
    }

    nonisolated private static func eventId(
        accountKey: String,
        limitID: String,
        sampledAt: Date,
        before: Int,
        after: Int
    ) -> String {
        "\(accountKey)|\(limitID)|\(Int(sampledAt.timeIntervalSince1970))|\(before)|\(after)"
    }
}
