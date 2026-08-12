import Foundation

nonisolated enum QuotaCycleBoundaryQuality: String, Sendable, Codable, Equatable {
    case observed
    case inferred
}

nonisolated enum QuotaAllowanceSegmentStartReason: String, Sendable, Codable, Equatable {
    case initial
    case extraReset
}

nonisolated struct QuotaCycleAllowanceSegment: Sendable, Codable, Equatable, Identifiable {
    var id: String
    var startAt: Date
    var endAt: Date?
    var baselineUsedPercent: Double
    var latestUsedPercent: Double
    var maximumUsedPercent: Double
    var firstSampleAt: Date
    var lastSampleAt: Date
    var startReason: QuotaAllowanceSegmentStartReason

    var observedUsedPercent: Double {
        max(0, maximumUsedPercent - baselineUsedPercent)
    }

    func contains(_ date: Date) -> Bool {
        date >= startAt && (endAt == nil || date < endAt!)
    }
}

nonisolated struct QuotaCycleRecord: Sendable, Codable, Equatable, Identifiable {
    var id: String
    var accountKey: String
    var app: UsageApp
    var limitID: String
    var limitKind: QuotaLimitKind
    var startAt: Date
    var endAt: Date
    var scheduledEndAt: Date
    var firstSampleAt: Date?
    var lastSampleAt: Date?
    var latestUsedPercent: Double
    var allowanceSegments: [QuotaCycleAllowanceSegment]
    var source: QuotaSnapshotSource
    var boundaryQuality: QuotaCycleBoundaryQuality

    private enum CodingKeys: String, CodingKey {
        case id, accountKey, app, limitID, limitKind
        case startAt, endAt, scheduledEndAt, firstSampleAt, lastSampleAt
        case latestUsedPercent, maximumUsedPercent, allowanceSegments
        case source, boundaryQuality
    }

    init(
        id: String,
        accountKey: String,
        app: UsageApp,
        limitID: String,
        limitKind: QuotaLimitKind,
        startAt: Date,
        endAt: Date,
        scheduledEndAt: Date,
        firstSampleAt: Date?,
        lastSampleAt: Date?,
        latestUsedPercent: Double,
        allowanceSegments: [QuotaCycleAllowanceSegment],
        source: QuotaSnapshotSource,
        boundaryQuality: QuotaCycleBoundaryQuality
    ) {
        self.id = id
        self.accountKey = accountKey
        self.app = app
        self.limitID = limitID
        self.limitKind = limitKind
        self.startAt = startAt
        self.endAt = endAt
        self.scheduledEndAt = scheduledEndAt
        self.firstSampleAt = firstSampleAt
        self.lastSampleAt = lastSampleAt
        self.latestUsedPercent = latestUsedPercent
        self.allowanceSegments = allowanceSegments
        self.source = source
        self.boundaryQuality = boundaryQuality
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        accountKey = try c.decode(String.self, forKey: .accountKey)
        app = try c.decode(UsageApp.self, forKey: .app)
        limitID = try c.decode(String.self, forKey: .limitID)
        limitKind = try c.decode(QuotaLimitKind.self, forKey: .limitKind)
        startAt = try c.decode(Date.self, forKey: .startAt)
        endAt = try c.decode(Date.self, forKey: .endAt)
        scheduledEndAt = try c.decodeIfPresent(Date.self, forKey: .scheduledEndAt) ?? endAt
        firstSampleAt = try c.decodeIfPresent(Date.self, forKey: .firstSampleAt)
        lastSampleAt = try c.decodeIfPresent(Date.self, forKey: .lastSampleAt)
        let legacyMaximum = try c.decodeIfPresent(Double.self, forKey: .maximumUsedPercent)
        latestUsedPercent = try c.decodeIfPresent(Double.self, forKey: .latestUsedPercent)
            ?? legacyMaximum
            ?? 0
        allowanceSegments = try c.decodeIfPresent(
            [QuotaCycleAllowanceSegment].self,
            forKey: .allowanceSegments
        ) ?? [QuotaCycleAllowanceSegment(
            id: "\(id)|allowance|legacy",
            startAt: startAt,
            endAt: nil,
            baselineUsedPercent: 0,
            latestUsedPercent: latestUsedPercent,
            maximumUsedPercent: legacyMaximum ?? latestUsedPercent,
            firstSampleAt: firstSampleAt ?? startAt,
            lastSampleAt: lastSampleAt ?? firstSampleAt ?? startAt,
            startReason: .initial
        )]
        source = try c.decode(QuotaSnapshotSource.self, forKey: .source)
        boundaryQuality = try c.decode(QuotaCycleBoundaryQuality.self, forKey: .boundaryQuality)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(accountKey, forKey: .accountKey)
        try c.encode(app, forKey: .app)
        try c.encode(limitID, forKey: .limitID)
        try c.encode(limitKind, forKey: .limitKind)
        try c.encode(startAt, forKey: .startAt)
        try c.encode(endAt, forKey: .endAt)
        try c.encode(scheduledEndAt, forKey: .scheduledEndAt)
        try c.encodeIfPresent(firstSampleAt, forKey: .firstSampleAt)
        try c.encodeIfPresent(lastSampleAt, forKey: .lastSampleAt)
        try c.encode(latestUsedPercent, forKey: .latestUsedPercent)
        try c.encode(allowanceSegments, forKey: .allowanceSegments)
        try c.encode(source, forKey: .source)
        try c.encode(boundaryQuality, forKey: .boundaryQuality)
    }

    var extraResetCount: Int {
        allowanceSegments.filter { $0.startReason == .extraReset }.count
    }

    var totalObservedUsedPercent: Double {
        allowanceSegments.reduce(0) { $0 + $1.observedUsedPercent }
    }

    /// 历史表展示的服务端额度消耗：初始额度取最高一次，重置后的每个新额度段再累加。
    /// 旧版重复 initial 段只取最大值，避免把迁移残留重复计算成 200%。
    var reportedUsedPercent: Double {
        let initialMaximum = allowanceSegments
            .filter { $0.startReason == .initial }
            .map { max(0, min(100, $0.maximumUsedPercent)) }
            .max() ?? max(0, latestUsedPercent)
        let extraResetMaximum = allowanceSegments
            .filter { $0.startReason == .extraReset }
            .reduce(0) { partial, segment in
                partial + max(0, min(100, segment.maximumUsedPercent))
            }
        return initialMaximum + extraResetMaximum
    }

    var latestAllowanceSegment: QuotaCycleAllowanceSegment? {
        allowanceSegments.max { $0.startAt < $1.startAt }
    }

    func contains(_ date: Date) -> Bool {
        date >= startAt && date < endAt
    }

    func isCurrent(at date: Date = Date()) -> Bool {
        contains(date)
    }

    func isComplete(at date: Date = Date()) -> Bool {
        endAt <= date
    }
}

nonisolated struct QuotaCycleAccountSegment: Sendable, Codable, Equatable, Identifiable {
    var id: String
    var accountKey: String
    var app: UsageApp
    var startAt: Date
    var endAt: Date?

    func contains(_ date: Date) -> Bool {
        date >= startAt && (endAt == nil || date < endAt!)
    }
}

nonisolated struct QuotaCyclePayload: Sendable, Codable, Equatable {
    static let currentVersion = 4

    var version: Int = Self.currentVersion
    var trackingStartedAt: Date = Date()
    var records: [QuotaCycleRecord] = []
    var accountSegments: [QuotaCycleAccountSegment] = []
}

enum QuotaCycleStore {
    nonisolated private static let fileName = "quota-cycle-history.json"
    nonisolated private static let bundleDirectory = "CCBar"
    nonisolated private static let extraResetMinimumDrop = 10.0
    nonisolated private static let nearZeroUsedPercent = 2.0
    nonisolated private static let nearZeroMinimumDrop = 3.0
    /// Codex 服务端返回的 reset_at 有秒级抖动（实测 1~3 秒）。周期 ID 内含秒级
    /// 时间戳，抖动会让精确 ID 匹配落空并误建重复周期；此容差用于把同一次重置
    /// 的相邻采样归并到同一条记录。
    nonisolated private static let resetJitterTolerance: TimeInterval = 60
    /// 半开区间收口后，相邻片段边界可能刚好相差 1 秒。
    nonisolated private static let resetDriftAdjacencyTolerance: TimeInterval = 1
    /// 短于此长度的记录视为被 closeOverlappingCycles 截断的残片（正常窗口最短 5 小时）。
    nonisolated private static let minimumShardDuration: TimeInterval = 60

    nonisolated static func load() -> QuotaCyclePayload {
        let url = fileURL()
        guard let data = try? Data(contentsOf: url),
              var payload = try? JSONDecoder().decode(QuotaCyclePayload.self, from: data),
              payload.version == QuotaCyclePayload.currentVersion || payload.version == 2 || payload.version == 3
        else {
            return QuotaCyclePayload()
        }
        // v4 之后仍可能收到会缓慢漂移的 Codex resetAt。每次载入都做幂等清理，
        // 让已经落盘的短周期残片也能在升级后立即恢复成一个真实周期。
        payload = cleaningUpLegacyPayload(payload)
        payload.version = QuotaCyclePayload.currentVersion
        return payload
    }

    nonisolated static func save(_ payload: QuotaCyclePayload) throws {
        let url = fileURL()
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(payload)
        try data.write(to: url, options: [.atomic])
    }

    /// 历史数据可能因 reset_at 漂移产生同一周期的重复记录：
    /// 部分记录被 closeOverlappingCycles 截断成残片，另有部分完整周期彼此重叠。
    /// 清理时删除秒级残片、合并重叠记录，并把「额度未回落、只是 resetAt 向后移动」
    /// 的相邻片段重新接回同一周期。真实额度回落仍保留为新周期。
    nonisolated static func cleaningUpLegacyPayload(_ payload: QuotaCyclePayload) -> QuotaCyclePayload {
        var next = payload
        next.records = next.records.filter { record in
            record.endAt.timeIntervalSince(record.startAt) >= Self.minimumShardDuration
        }
        next.records = Self.deduplicatingOverlapping(next.records)
        next.records = Self.coalescingResetDriftFragments(next.records)
        return next
    }

    nonisolated private static func coalescingResetDriftFragments(
        _ records: [QuotaCycleRecord]
    ) -> [QuotaCycleRecord] {
        let grouped = Dictionary(grouping: records) { record in
            "\(record.accountKey)|\(record.app.rawValue)|\(record.limitKind.rawValue)|\(record.limitID)"
        }
        var result: [QuotaCycleRecord] = []
        for group in grouped.values {
            let sorted = group.sorted { lhs, rhs in
                if lhs.startAt == rhs.startAt { return lhs.endAt < rhs.endAt }
                return lhs.startAt < rhs.startAt
            }
            guard var current = sorted.first else { continue }
            for next in sorted.dropFirst() {
                if isResetDriftContinuation(earlier: current, later: next) {
                    current = mergingResetDriftContinuation(earlier: current, later: next)
                } else {
                    result.append(current)
                    current = next
                }
            }
            result.append(current)
        }
        return result.sorted { lhs, rhs in
            if lhs.endAt == rhs.endAt { return lhs.id < rhs.id }
            return lhs.endAt > rhs.endAt
        }
    }

    nonisolated private static func isResetDriftContinuation(
        earlier: QuotaCycleRecord,
        later: QuotaCycleRecord
    ) -> Bool {
        let isAdjacent = abs(earlier.endAt.timeIntervalSince(later.startAt))
            <= Self.resetDriftAdjacencyTolerance
        let endedBeforeScheduledReset = earlier.endAt < earlier.scheduledEndAt
        let usageDidNotReset = !isExtraReset(
            previousUsedPercent: earlier.latestUsedPercent,
            usedPercent: later.latestUsedPercent
        )
        return isAdjacent && endedBeforeScheduledReset && usageDidNotReset
    }

    nonisolated private static func mergingResetDriftContinuation(
        earlier: QuotaCycleRecord,
        later: QuotaCycleRecord
    ) -> QuotaCycleRecord {
        // 保留较新的 ID，让当前 rollup 与后续采样继续命中同一条记录；边界则向前
        // 扩回第一个片段，额度段也在伪切点处合并，避免把同一额度误当重置。
        var merged = later
        merged.startAt = min(earlier.startAt, later.startAt)
        if let earlierFirst = earlier.firstSampleAt {
            merged.firstSampleAt = min(merged.firstSampleAt ?? earlierFirst, earlierFirst)
        }
        if let earlierLast = earlier.lastSampleAt {
            merged.lastSampleAt = max(merged.lastSampleAt ?? earlierLast, earlierLast)
        }
        merged.allowanceSegments = mergingContinuationAllowanceSegments(
            earlier.allowanceSegments,
            later.allowanceSegments
        )
        merged.source = preferredSource(earlier.source, later.source)
        if earlier.boundaryQuality == .observed {
            merged.boundaryQuality = .observed
        }
        return merged
    }

    nonisolated private static func mergingContinuationAllowanceSegments(
        _ earlier: [QuotaCycleAllowanceSegment],
        _ later: [QuotaCycleAllowanceSegment]
    ) -> [QuotaCycleAllowanceSegment] {
        guard var earlierLast = earlier.last, var laterFirst = later.first else {
            return earlier + later
        }
        earlierLast.id = laterFirst.id
        earlierLast.endAt = laterFirst.endAt
        earlierLast.latestUsedPercent = laterFirst.latestUsedPercent
        earlierLast.maximumUsedPercent = max(
            earlierLast.maximumUsedPercent,
            laterFirst.maximumUsedPercent
        )
        earlierLast.firstSampleAt = min(earlierLast.firstSampleAt, laterFirst.firstSampleAt)
        earlierLast.lastSampleAt = max(earlierLast.lastSampleAt, laterFirst.lastSampleAt)
        laterFirst = earlierLast
        return Array(earlier.dropLast()) + [laterFirst] + Array(later.dropFirst())
    }

    nonisolated private static func deduplicatingOverlapping(_ records: [QuotaCycleRecord]) -> [QuotaCycleRecord] {
        var result: [QuotaCycleRecord] = []
        var consumed = Set<String>()
        for record in records.sorted(by: { $0.endAt > $1.endAt }) {
            guard !consumed.contains(record.id) else { continue }
            var merged = record
            consumed.insert(record.id)
            for other in records where !consumed.contains(other.id) {
                guard other.accountKey == merged.accountKey,
                      other.app == merged.app,
                      other.limitKind == merged.limitKind,
                      intervalsOverlap(merged, other)
                else { continue }
                consumed.insert(other.id)
                merged = merging(base: merged, other: other)
            }
            result.append(merged)
        }
        return result
    }

    nonisolated private static func intervalsOverlap(_ a: QuotaCycleRecord, _ b: QuotaCycleRecord) -> Bool {
        a.startAt < b.endAt && b.startAt < a.endAt
    }

    nonisolated private static func merging(base: QuotaCycleRecord, other: QuotaCycleRecord) -> QuotaCycleRecord {
        var merged = base
        if let otherFirst = other.firstSampleAt {
            merged.firstSampleAt = min(merged.firstSampleAt ?? otherFirst, otherFirst)
        }
        if let otherLast = other.lastSampleAt {
            merged.lastSampleAt = max(merged.lastSampleAt ?? otherLast, otherLast)
        }
        if let baseLast = merged.lastSampleAt,
           let otherLast = other.lastSampleAt,
           otherLast > baseLast
        {
            merged.latestUsedPercent = other.latestUsedPercent
        }
        merged.allowanceSegments = mergedAllowanceSegments(merged.allowanceSegments, other.allowanceSegments)
        merged.source = preferredSource(merged.source, other.source)
        if other.boundaryQuality == .observed {
            merged.boundaryQuality = .observed
        }
        return merged
    }

    nonisolated private static func mergedAllowanceSegments(
        _ a: [QuotaCycleAllowanceSegment],
        _ b: [QuotaCycleAllowanceSegment]
    ) -> [QuotaCycleAllowanceSegment] {
        let all = (a + b).sorted { $0.startAt < $1.startAt }
        var result: [QuotaCycleAllowanceSegment] = []
        for segment in all {
            if var last = result.last {
                if abs(last.startAt.timeIntervalSince(segment.startAt)) < 1 {
                    if segment.lastSampleAt >= last.lastSampleAt {
                        result[result.count - 1] = segment
                    }
                    continue
                }
                if last.endAt == nil {
                    result[result.count - 1].endAt = segment.startAt
                }
            }
            result.append(segment)
        }
        return result
    }

    /// 只记录主账号的标准 5 小时 / 周窗口；导入账号和模型专项窗口由调用方排除。
    nonisolated static func record(
        payload: QuotaCyclePayload,
        accountKey: String,
        app: UsageApp,
        snapshot: QuotaSnapshot,
        source: QuotaSnapshotSource,
        sampledAt: Date
    ) -> QuotaCyclePayload {
        var next = payload
        updateAccountSegments(
            in: &next,
            accountKey: accountKey,
            app: app,
            sampledAt: sampledAt
        )
        let limits = [snapshot.primaryLimit, snapshot.secondaryLimit].compactMap { $0 }
        // 不按 is_active 过滤：is_active 只表示「当前哪个限制在起约束作用」，
        // 非当前约束的窗口（如 5 小时未满时的 weekly）同样返回有效的 percent / resets_at，
        // 过滤会导致周期记录停更，页面停留在旧值。
        for limit in limits where limit.kind == .fiveHour || limit.kind == .weekly {
            guard let scheduledEndAt = limit.window.resetsAt,
                  let seconds = windowSeconds(for: limit),
                  seconds > 0
            else { continue }

            let startAt = scheduledEndAt.addingTimeInterval(-TimeInterval(seconds))
            let usedPercent = normalizedPercent(limit.window.usedPercent)
            let boundaryQuality: QuotaCycleBoundaryQuality = limit.window.windowSeconds == nil
                ? .inferred
                : .observed
            let id = cycleID(
                accountKey: accountKey,
                limitID: limit.id,
                endAt: scheduledEndAt
            )
            let matchIndex = next.records.firstIndex(where: { $0.id == id })
                ?? next.records.firstIndex(where: { candidate in
                    candidate.accountKey == accountKey
                        && candidate.app == app
                        && candidate.limitKind == limit.kind
                        && candidate.endAt > sampledAt
                        && abs(candidate.endAt.timeIntervalSince(scheduledEndAt)) < Self.resetJitterTolerance
                })
                ?? next.records.indices
                    .filter { index in
                        let candidate = next.records[index]
                        return candidate.accountKey == accountKey
                            && candidate.app == app
                            && candidate.limitKind == limit.kind
                            && candidate.endAt > sampledAt
                            && !isExtraReset(
                                previousUsedPercent: candidate.latestUsedPercent,
                                usedPercent: usedPercent
                            )
                    }
                    .max { lhs, rhs in
                        let lhsSample = next.records[lhs].lastSampleAt ?? .distantPast
                        let rhsSample = next.records[rhs].lastSampleAt ?? .distantPast
                        return lhsSample < rhsSample
                    }
            if let index = matchIndex {
                let wasActive = next.records[index].endAt > sampledAt
                next.records[index].limitKind = limit.kind
                next.records[index].startAt = min(next.records[index].startAt, startAt)
                next.records[index].scheduledEndAt = scheduledEndAt
                next.records[index].endAt = wasActive
                    ? scheduledEndAt
                    : min(next.records[index].endAt, scheduledEndAt)
                next.records[index].firstSampleAt = min(next.records[index].firstSampleAt ?? sampledAt, sampledAt)
                next.records[index].lastSampleAt = max(next.records[index].lastSampleAt ?? sampledAt, sampledAt)
                updateAllowanceSegments(
                    record: &next.records[index],
                    usedPercent: usedPercent,
                    sampledAt: sampledAt,
                    trackingStartedAt: next.trackingStartedAt
                )
                next.records[index].source = preferredSource(next.records[index].source, source)
                if boundaryQuality == .observed {
                    next.records[index].boundaryQuality = .observed
                }
            } else {
                closeOverlappingCycles(
                    in: &next,
                    accountKey: accountKey,
                    app: app,
                    limitKind: limit.kind,
                    newCycleStartAt: startAt
                )
                next.records.append(QuotaCycleRecord(
                    id: id,
                    accountKey: accountKey,
                    app: app,
                    limitID: limit.id,
                    limitKind: limit.kind,
                    startAt: startAt,
                    endAt: scheduledEndAt,
                    scheduledEndAt: scheduledEndAt,
                    firstSampleAt: sampledAt,
                    lastSampleAt: sampledAt,
                    latestUsedPercent: usedPercent,
                    allowanceSegments: [initialAllowanceSegment(
                        cycleID: id,
                        cycleStartAt: startAt,
                        trackingStartedAt: next.trackingStartedAt,
                        usedPercent: usedPercent,
                        sampledAt: sampledAt
                    )],
                    source: source,
                    boundaryQuality: boundaryQuality
                ))
            }
        }
        next.records.sort { lhs, rhs in
            if lhs.endAt == rhs.endAt { return lhs.id < rhs.id }
            return lhs.endAt > rhs.endAt
        }
        return next
    }

    nonisolated private static func updateAllowanceSegments(
        record: inout QuotaCycleRecord,
        usedPercent: Double,
        sampledAt: Date,
        trackingStartedAt: Date
    ) {
        let previousUsedPercent = record.latestUsedPercent
        record.latestUsedPercent = usedPercent
        guard !record.allowanceSegments.isEmpty else {
            record.allowanceSegments = [initialAllowanceSegment(
                cycleID: record.id,
                cycleStartAt: record.startAt,
                trackingStartedAt: trackingStartedAt,
                usedPercent: usedPercent,
                sampledAt: sampledAt
            )]
            return
        }

        if isExtraReset(previousUsedPercent: previousUsedPercent, usedPercent: usedPercent) {
            let lastIndex = record.allowanceSegments.index(before: record.allowanceSegments.endIndex)
            record.allowanceSegments[lastIndex].endAt = sampledAt
            record.allowanceSegments.append(QuotaCycleAllowanceSegment(
                id: allowanceSegmentID(cycleID: record.id, startAt: sampledAt),
                startAt: sampledAt,
                endAt: nil,
                baselineUsedPercent: usedPercent,
                latestUsedPercent: usedPercent,
                maximumUsedPercent: usedPercent,
                firstSampleAt: sampledAt,
                lastSampleAt: sampledAt,
                startReason: .extraReset
            ))
            return
        }

        let lastIndex = record.allowanceSegments.index(before: record.allowanceSegments.endIndex)
        record.allowanceSegments[lastIndex].latestUsedPercent = usedPercent
        record.allowanceSegments[lastIndex].maximumUsedPercent = max(
            record.allowanceSegments[lastIndex].maximumUsedPercent,
            usedPercent
        )
        record.allowanceSegments[lastIndex].lastSampleAt = max(
            record.allowanceSegments[lastIndex].lastSampleAt,
            sampledAt
        )
    }

    nonisolated private static func initialAllowanceSegment(
        cycleID: String,
        cycleStartAt: Date,
        trackingStartedAt: Date,
        usedPercent: Double,
        sampledAt: Date
    ) -> QuotaCycleAllowanceSegment {
        let trackedFromCycleStart = trackingStartedAt <= cycleStartAt
        let startAt = trackedFromCycleStart ? cycleStartAt : sampledAt
        let baselineUsedPercent = trackedFromCycleStart ? 0 : usedPercent
        return QuotaCycleAllowanceSegment(
            id: allowanceSegmentID(cycleID: cycleID, startAt: startAt),
            startAt: startAt,
            endAt: nil,
            baselineUsedPercent: baselineUsedPercent,
            latestUsedPercent: usedPercent,
            maximumUsedPercent: usedPercent,
            firstSampleAt: sampledAt,
            lastSampleAt: sampledAt,
            startReason: .initial
        )
    }

    nonisolated private static func closeOverlappingCycles(
        in payload: inout QuotaCyclePayload,
        accountKey: String,
        app: UsageApp,
        limitKind: QuotaLimitKind,
        newCycleStartAt: Date
    ) {
        for index in payload.records.indices {
            guard payload.records[index].accountKey == accountKey,
                  payload.records[index].app == app,
                  payload.records[index].limitKind == limitKind,
                  payload.records[index].startAt < newCycleStartAt,
                  payload.records[index].endAt > newCycleStartAt
            else { continue }

            payload.records[index].endAt = newCycleStartAt
            if let segmentIndex = payload.records[index].allowanceSegments.indices.last,
               payload.records[index].allowanceSegments[segmentIndex].endAt == nil
            {
                payload.records[index].allowanceSegments[segmentIndex].endAt = newCycleStartAt
            }
        }
    }

    nonisolated private static func isExtraReset(
        previousUsedPercent: Double,
        usedPercent: Double
    ) -> Bool {
        let drop = previousUsedPercent - usedPercent
        return drop >= extraResetMinimumDrop
            || (usedPercent <= nearZeroUsedPercent && drop >= nearZeroMinimumDrop)
    }

    nonisolated private static func normalizedPercent(_ value: Double) -> Double {
        max(0, min(100, value))
    }

    nonisolated private static func allowanceSegmentID(cycleID: String, startAt: Date) -> String {
        "\(cycleID)|allowance|\(Int(startAt.timeIntervalSince1970.rounded()))"
    }

    nonisolated private static func updateAccountSegments(
        in payload: inout QuotaCyclePayload,
        accountKey: String,
        app: UsageApp,
        sampledAt: Date
    ) {
        if let activeIndex = payload.accountSegments.lastIndex(where: { $0.app == app && $0.endAt == nil }) {
            if payload.accountSegments[activeIndex].accountKey == accountKey {
                return
            }
            payload.accountSegments[activeIndex].endAt = sampledAt
        }

        let isFirstAccount = !payload.accountSegments.contains { $0.app == app }
        let startAt = isFirstAccount ? payload.trackingStartedAt : sampledAt
        payload.accountSegments.append(QuotaCycleAccountSegment(
            id: "\(app.rawValue)|\(accountKey)|\(Int(sampledAt.timeIntervalSince1970.rounded()))",
            accountKey: accountKey,
            app: app,
            startAt: startAt,
            endAt: nil
        ))
    }

    nonisolated static func fileURL() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return support
            .appendingPathComponent(bundleDirectory, isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
    }

    nonisolated private static func windowSeconds(for limit: QuotaLimit) -> Int? {
        if let seconds = limit.window.windowSeconds { return seconds }
        switch limit.kind {
        case .fiveHour: return 5 * 60 * 60
        case .weekly: return 7 * 24 * 60 * 60
        case .modelWeekly, .unknown: return nil
        }
    }

    nonisolated private static func cycleID(
        accountKey: String,
        limitID: String,
        endAt: Date
    ) -> String {
        let resetSecond = Int(endAt.timeIntervalSince1970.rounded())
        return "\(accountKey)|\(limitID)|\(resetSecond)"
    }

    nonisolated private static func preferredSource(
        _ current: QuotaSnapshotSource,
        _ incoming: QuotaSnapshotSource
    ) -> QuotaSnapshotSource {
        func rank(_ source: QuotaSnapshotSource) -> Int {
            switch source {
            case .api: return 4
            case .cliFallback: return 3
            case .local: return 2
            case .cache: return 1
            }
        }
        return rank(incoming) >= rank(current) ? incoming : current
    }
}
