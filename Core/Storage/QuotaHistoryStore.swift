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
    /// 同窗对齐容差：服务端每次返回的 resets_at 都有亚秒~秒级抖动（实测 Claude
    /// 0.2~0.4 秒、Codex 1~3 秒），同窗口的相邻采样差在容差量级；差出半小时以上
    /// 必须视为窗口已滚动（跨周 / 制式换档）。与 `QuotaCycleStore`
    /// 的 `windowAlignmentTolerance` 语义一致。
    nonisolated private static let windowAlignmentTolerance: TimeInterval = 30 * 60

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
        // seriesKey = "\(accountKey)|\(kind)"；仅迁移恰好是旧常量键 "claude:primary" 的条目，
        // 与下方 events 的迁移条件一致；已哈希账号键（"claude:primary:hash"）与
        // 其他账号的系列（如 "codex:primary:*"）一律保留，不能误迁。
        next.lastSamples = next.lastSamples.reduce(into: [:]) { result, entry in
            guard entry.value.accountKey == legacyKey else {
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

        guard let previous = sameLimitPrevious else { return next }

        // 断链自愈：lastSample 与同系列最后一条事件脱节（同窗、采样晚于链尾且值不同）
        // 时，基线已被旧值/残留污染（现象是链上出现连续「before 恒定」的假差值）。
        // 以链尾为有效基线，本次采样与链尾相等时不产事件，等于直接把链条接回真值；
        // 等值或后续变化采样则按链尾差分，虚假涨跌无法继续发生。
        var baseline = previous
        if let tail = next.events.last(where: { $0.accountKey == accountKey && $0.limitKind == limit.kind }),
           isSameWindow(previous.resetsAt, tail.resetsAt),
           previous.sampledAt >= tail.sampledAt,
           previous.remainingPercent != tail.afterRemainingPercent
        {
            baseline = QuotaHistorySample(
                accountKey: tail.accountKey,
                app: tail.app,
                kind: tail.kind,
                sampledAt: tail.sampledAt,
                limitID: tail.limitID,
                limitKind: tail.limitKind,
                remainingPercent: tail.afterRemainingPercent,
                resetsAt: tail.resetsAt
            )
        }

        guard baseline.remainingPercent != remaining else { return next }

        // 跨窗闸：基线窗口与本次采样窗口不同窗（resets_at 偏移超出抖动容差）时，
        // 视为窗口已滚动（跨周重置）或旧窗口残留值窜入，不产变动事件，仅把本次
        // 采样写为新基线；旧窗口事件保持独立历史，互不差分。
        guard isSameWindow(baseline.resetsAt, limit.window.resetsAt) else { return next }

        let delta = remaining - baseline.remainingPercent
        next.events.append(QuotaChangeEvent(
            id: eventId(
                accountKey: accountKey,
                limitID: limit.id,
                sampledAt: sampledAt,
                before: baseline.remainingPercent,
                after: remaining
            ),
            accountKey: accountKey,
            app: app,
            kind: kind,
            sampledAt: sampledAt,
            limitID: limit.id,
            limitKind: limit.kind,
            beforeRemainingPercent: baseline.remainingPercent,
            afterRemainingPercent: remaining,
            deltaPercent: delta,
            resetsAt: limit.window.resetsAt
        ))
        return next
    }

    /// 同窗判定：两端 resets_at 都给定时差在 `windowAlignmentTolerance`（半小时）内；
    /// 任一端缺失时无从判定，按同窗处理（断链自愈规则仍兜底异常值）。
    nonisolated private static func isSameWindow(_ a: Date?, _ b: Date?) -> Bool {
        guard let a, let b else { return true }
        return abs(a.timeIntervalSince(b)) <= windowAlignmentTolerance
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
    /// 先做一次幂等的断链清洗（见 `cleanupInconsistentChains`），再按时间窗裁剪。
    nonisolated private static func prune(_ payload: QuotaHistoryPayload, now: Date) -> QuotaHistoryPayload {
        let cleaned = cleanupInconsistentChains(payload)
        let start = todayStart(now: now)
        let cutoff = Calendar.current.date(
            byAdding: .day,
            value: -(Self.retentionDays - 1),
            to: start
        ) ?? start
        var next = cleaned
        next.dayStart = start
        next.events = next.events.filter { $0.sampledAt >= cutoff }
        next.lastSamples = next.lastSamples.filter { $0.value.sampledAt >= cutoff }
        return next
    }

    /// 幂等清洗：跨窗差分与断链差分的事件基于「窗口边界变化」或「被旧值污染的基线」
    /// 生成，都是虚假变动。按系列保留「链首」与「与前一保留事件同窗且数值衔接」的事件，
    /// 删除其余；并把同窗内与链尾脱节的 lastSample 回滚为链尾值，保证后续采样从干净
    /// 基线继续（链首事件无法可靠判定真伪，保留）。
    nonisolated static func cleanupInconsistentChains(_ payload: QuotaHistoryPayload) -> QuotaHistoryPayload {
        var keptBySeries: [String: QuotaChangeEvent] = [:]
        var cleaned: [QuotaChangeEvent] = []
        for event in payload.events {
            let series = "\(event.accountKey)|\(event.limitKind.rawValue)"
            let keep = keptBySeries[series].map { prev in
                isSameWindow(prev.resetsAt, event.resetsAt)
                    && prev.afterRemainingPercent == event.beforeRemainingPercent
            } ?? true
            if keep {
                cleaned.append(event)
                keptBySeries[series] = event
            }
        }

        var next = payload
        next.events = cleaned

        var samples = payload.lastSamples
        for sample in samples.values {
            guard sample.limitKind == .fiveHour || sample.limitKind == .weekly else { continue }
            guard let tail = cleaned.last(where: {
                $0.accountKey == sample.accountKey
                    && $0.limitKind == sample.limitKind
                    && $0.sampledAt <= sample.sampledAt
            }) else { continue }
            guard tail.limitID == sample.limitID,
                  isSameWindow(tail.resetsAt, sample.resetsAt),
                  sample.remainingPercent != tail.afterRemainingPercent
            else { continue }
            var fixed = sample
            fixed.remainingPercent = tail.afterRemainingPercent
            samples[seriesKey(accountKey: sample.accountKey, limitKind: sample.limitKind)] = fixed
        }
        next.lastSamples = samples
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
