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
    static let currentVersion = 2

    var version: Int = Self.currentVersion
    var dayStart: Date = QuotaHistoryStore.todayStart()
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

    nonisolated static func load(now: Date = Date()) -> QuotaHistoryPayload {
        let url = fileURL()
        guard let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(QuotaHistoryPayload.self, from: data),
              payload.version == QuotaHistoryPayload.currentVersion
        else {
            return QuotaHistoryPayload(dayStart: todayStart(now: now))
        }
        return prune(payload, now: now)
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

    /// 旧版 Claude 主账号恒用 `claude:primary`，历史无法再拆分。
    /// 首次取得当前邮箱后将这批当日数据一次性归入当前账号。
    nonisolated static func migratingLegacyClaudeAccountKey(
        _ payload: QuotaHistoryPayload,
        to accountKey: String
    ) -> QuotaHistoryPayload {
        let legacyKey = "claude:primary"
        guard accountKey != legacyKey else { return payload }
        var next = payload
        if var legacy = next.lastSamples.removeValue(forKey: legacyKey) {
            legacy.accountKey = accountKey
            if let existing = next.lastSamples[accountKey], existing.sampledAt > legacy.sampledAt {
                next.lastSamples[accountKey] = existing
            } else {
                next.lastSamples[accountKey] = legacy
            }
        }
        for index in next.events.indices where next.events[index].accountKey == legacyKey {
            next.events[index].accountKey = accountKey
        }
        return next
    }

    nonisolated static func record(
        payload: QuotaHistoryPayload,
        accountKey: String,
        app: QuotaApp,
        kind: QuotaHistoryAccountKind,
        snapshot: QuotaSnapshot,
        sampledAt: Date
    ) -> QuotaHistoryPayload {
        guard let primary = snapshot.primaryLimit else {
            return prune(payload, now: sampledAt)
        }

        var next = prune(payload, now: sampledAt)
        let remaining = roundedPercent(primary.window.remainingPercent)
        let previous = next.lastSamples[accountKey]
        let sameLimitPrevious = previous.flatMap {
            $0.limitID == primary.id && $0.limitKind == primary.kind ? $0 : nil
        }

        // 服务端把主额度从 5H 切成 WK（或恢复）时，两者不是同一条曲线。
        // 清掉该账号当天旧基准和事件，从新窗口重新采样，避免制造虚假涨跌。
        if let previous,
           previous.limitID != primary.id || previous.limitKind != primary.kind
        {
            next.events.removeAll { $0.accountKey == accountKey }
            next.lastSamples.removeValue(forKey: accountKey)
        }

        next.lastSamples[accountKey] = QuotaHistorySample(
            accountKey: accountKey,
            app: app,
            kind: kind,
            sampledAt: sampledAt,
            limitID: primary.id,
            limitKind: primary.kind,
            remainingPercent: remaining,
            resetsAt: primary.window.resetsAt
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
                limitID: primary.id,
                sampledAt: sampledAt,
                before: previous.remainingPercent,
                after: remaining
            ),
            accountKey: accountKey,
            app: app,
            kind: kind,
            sampledAt: sampledAt,
            limitID: primary.id,
            limitKind: primary.kind,
            beforeRemainingPercent: previous.remainingPercent,
            afterRemainingPercent: remaining,
            deltaPercent: delta,
            resetsAt: primary.window.resetsAt
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

    nonisolated private static func prune(_ payload: QuotaHistoryPayload, now: Date) -> QuotaHistoryPayload {
        let start = todayStart(now: now)
        guard Calendar.current.isDate(payload.dayStart, inSameDayAs: start) else {
            return QuotaHistoryPayload(dayStart: start)
        }

        var next = payload
        next.dayStart = start
        next.events = next.events.filter { Calendar.current.isDate($0.sampledAt, inSameDayAs: start) }
        next.lastSamples = next.lastSamples.filter { Calendar.current.isDate($0.value.sampledAt, inSameDayAs: start) }
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
