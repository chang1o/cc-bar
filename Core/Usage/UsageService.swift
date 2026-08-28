import Foundation
import Observation

/// 协调 JSONL 扫描 → 聚合 → 持久化 → 通知 AppState 的入口。
@MainActor
@Observable
final class UsageService {
    let aggregator = UsageAggregator()
    let conversationAggregator = ConversationAggregator()
    let cycleAggregator = CycleUsageAggregator()
    private(set) var isScanning = false
    private(set) var isCycleRebuilding = false
    private(set) var isRefreshingPricingCatalog = false
    private(set) var lastScanAt: Date?
    private(set) var lastError: String?
    /// 进行中的全量重算 / 周期重建进度；空闲时为 nil。设置页"重新计算"期间展示。
    private(set) var scanProgress: ScanProgress?

    private weak var appState: AppState?
    private var scanQueued = false
    private var requiresFullRebuild = false
    private var loadedRollupGeneration: String?
    private var loadedCycleGeneration: String?
    private var cycleInitialRebuildCompletedAt: Date?
    private var cycleInitialRebuildCompletedApps: Set<UsageApp> = []
    /// Cursor 远端日桶独立于本地 scan-state / usage-rollup 的持久化状态。
    private var cursorUsageCache = CursorUsageCachePayload()
    private var cursorRemoteAccountID: String?
    private var cursorRemoteBackoffUntil: Date?
    private(set) var isRefreshingCursorRemoteUsage = false
    private(set) var cursorRemoteUsageError: String?

    /// 统计页读取的完整 Cursor 自然日覆盖范围。只有身份匹配的独立远端缓存会进入此集合。
    var cursorUsageCoveredDayRanges: [CursorUsageDayRange] {
        cursorUsageCache.coveredDayRanges
    }

    func isCursorRemoteUsageCovered(_ range: Range<Date>) -> Bool {
        cursorUsageCache.coveredDayRanges.missingRanges(in: range).isEmpty
    }
    /// 上一轮成功提交的 ScanState 常驻内存，避免每轮扫描都从磁盘重读重解码
    /// scan-state.json（随文件数和 seen ID 增长，本地实测已近 1MB）。
    /// 冷启动首轮才从磁盘恢复；持久化失败时清空内存副本，
    /// 由 requiresFullRebuild 强制下轮全量重建。
    private var cachedScanState: ScanState?

    func bootstrap(appState: AppState) async {
        self.appState = appState
        // 日聚合与对话两份主 rollup 必须同代；周期 rollup 也只在同代、同价格指纹时恢复。
        // rollup 可能较大（conversation-rollup 实测可达数 MB），三个 load 都是磁盘读取 +
        // JSON 解码，统一放到后台线程，避免启动时阻塞主线程、菜单栏图标卡顿。
        let (payload, conversationPayload, cyclePayload, cursorPayload) = await Task.detached(priority: .utility) {
            (
                UsageRollupCache.load(),
                ConversationRollupCache.load(),
                CycleUsageRollupCache.load(),
                CursorUsageCache.load()
            )
        }.value
        cursorUsageCache = cursorPayload
        let generationsMatch = !payload.generationID.isEmpty
            && payload.generationID == conversationPayload.generationID
        if generationsMatch {
            aggregator.load(from: payload.buckets)
            conversationAggregator.load(infos: conversationPayload.infos, buckets: conversationPayload.buckets)
            loadedRollupGeneration = payload.generationID
            let validCycleIDs = Set(appState.quotaCycles.records.map(\.id))
            let rollupCycleIDs = Set(cyclePayload.buckets.map(\.cycleID))
            if cyclePayload.generationID == payload.generationID,
               cyclePayload.pricingFingerprint == payload.pricingFingerprint,
               rollupCycleIDs.isSubset(of: validCycleIDs) {
                cycleAggregator.load(from: cyclePayload.buckets)
                loadedCycleGeneration = cyclePayload.generationID
                cycleInitialRebuildCompletedAt = cyclePayload.initialRebuildCompletedAt
                cycleInitialRebuildCompletedApps = cyclePayload.effectiveInitialRebuildCompletedApps
            } else {
                cycleAggregator.load(from: [])
                loadedCycleGeneration = nil
                cycleInitialRebuildCompletedAt = nil
                cycleInitialRebuildCompletedApps = []
            }
            lastScanAt = max(payload.updatedAt, conversationPayload.updatedAt)
        } else {
            aggregator.load(from: [])
            conversationAggregator.load(infos: [], buckets: [])
            cycleAggregator.load(from: [])
            requiresFullRebuild = true
            loadedRollupGeneration = nil
            loadedCycleGeneration = nil
            cycleInitialRebuildCompletedAt = nil
            cycleInitialRebuildCompletedApps = []
            lastScanAt = nil
        }
        // 个人历史用量一次性补录：见 ImportedUsageBackfill 注释。这里先合并一次保证扫描前即可展示；
        // runScan 每轮还会按同样规则重新合并，兜底缓存失效清空聚合器的情况。文件不存在时是纯 no-op。
        let existingClaudeDays = Set(aggregator.snapshotLocal().filter { $0.app == .claude }.map(\.day))
        aggregator.ingestLocal(ImportedUsageBackfill.loadMissingEntries(app: .claude, existingDays: existingClaudeDays))
        publishTotals()
        // 远端价格目录后台刷新：非阻塞，isDue 内部判断是否真的需要发请求，刷新结果由下次扫描自然拾取。
        PricingCatalogStore.shared.refreshIfNeeded()
    }

    /// 仅在 Cursor 身份确认后恢复与该身份绑定的远端快照。缓存身份不匹配时，
    /// 立即从内存隔离旧桶；下一次完整远端拉取才会写入新账号数据。
    func activateCursorRemoteUsage(accountID: String) {
        let normalizedID = accountID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedID.isEmpty else { return }
        guard cursorRemoteAccountID?.caseInsensitiveCompare(normalizedID) != .orderedSame else { return }

        cursorRemoteAccountID = normalizedID
        if cursorUsageCache.accountID?.caseInsensitiveCompare(normalizedID) == .orderedSame {
            aggregator.loadRemote(from: cursorUsageCache.buckets)
        } else {
            aggregator.loadRemote(from: [])
            cursorUsageCache = CursorUsageCachePayload(accountID: normalizedID)
        }
        cursorRemoteUsageError = nil
        cursorRemoteBackoffUntil = nil
        publishTotals()
    }

    /// 拉取 Cursor 最近变动的远端日桶。首次请求可从计费周期起点开始；后续只重拉
    /// 今天及其前两天，成功后按完整自然日替换，绝不累计重复窗口。
    ///
    /// 返回 401 时由 AppState 负责只读重载 Cursor.app 登录态并最多重试一次。
    @discardableResult
    func refreshCursorRemoteUsage(
        session: CursorAuthSession,
        billingWindow: Range<Date>?,
        now: Date = Date(),
        calendar: Calendar = .current
    ) async -> CursorUsageError? {
        activateCursorRemoteUsage(accountID: session.userID)
        guard !isRefreshingCursorRemoteUsage else { return nil }
        if let backoffUntil = cursorRemoteBackoffUntil, backoffUntil > now {
            cursorRemoteUsageError = "Cursor usage rate limited; retry later"
            return nil
        }

        let today = calendar.startOfDay(for: now)
        let recentStart = calendar.date(byAdding: .day, value: -2, to: today) ?? today
        let hasCoverage = !cursorUsageCache.coveredDayRanges.isEmpty
        let initialStart = billingWindow.map { calendar.startOfDay(for: $0.lowerBound) }
        let from = hasCoverage ? recentStart : (initialStart ?? recentStart)
        guard from < now else { return nil }

        isRefreshingCursorRemoteUsage = true
        defer { isRefreshingCursorRemoteUsage = false }
        let result = await CursorUsageFetcher.fetch(
            cookieHeader: session.cookieHeader,
            from: from,
            to: now,
            calendar: calendar
        )
        switch result {
        case .failure(let error):
            cursorRemoteUsageError = error.description
            if error.isRateLimited {
                cursorRemoteBackoffUntil = now.addingTimeInterval(10 * 60)
            }
            return error
        case .success(let fetched):
            await storeCursorRemoteUsage(fetched, accountID: session.userID, updatedAt: now)
            return nil
        }
    }

    /// Stats 选择到未覆盖的有限时间范围时，按月补拉缺口。`all` 不会传入这里，
    /// 以免后台无界回溯；界面只消费现有缓存，不展示覆盖状态。
    @discardableResult
    func loadCursorRemoteUsageHistory(
        session: CursorAuthSession,
        range: Range<Date>,
        now: Date = Date(),
        calendar: Calendar = .current
    ) async -> CursorUsageError? {
        activateCursorRemoteUsage(accountID: session.userID)
        guard let requestedRange = normalizedCursorHistoryRange(range, now: now, calendar: calendar) else {
            return nil
        }

        // 与周期刷新共用一个远端槽，避免相同日桶并发覆盖。这里等待正在进行的短刷新，
        // 让用户切换历史范围时的请求不会被悄悄丢弃。
        while isRefreshingCursorRemoteUsage {
            guard !Task.isCancelled else { return nil }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }

        let missing = cursorUsageCache.coveredDayRanges.missingRanges(in: requestedRange)
        guard !missing.isEmpty else { return nil }

        if let backoffUntil = cursorRemoteBackoffUntil, backoffUntil > now {
            cursorRemoteUsageError = "Cursor usage rate limited; retry later"
            return nil
        }

        isRefreshingCursorRemoteUsage = true
        defer { isRefreshingCursorRemoteUsage = false }

        for chunk in missing.flatMap({ cursorHistoryMonthChunks(for: $0, calendar: calendar) }) {
            guard !Task.isCancelled else { return nil }
            let fetchEnd = min(chunk.upperBound, now)
            guard chunk.lowerBound < fetchEnd else { continue }

            let result = await CursorUsageFetcher.fetch(
                cookieHeader: session.cookieHeader,
                from: chunk.lowerBound,
                to: fetchEnd,
                calendar: calendar
            )
            switch result {
            case .failure(let error):
                cursorRemoteUsageError = error.description
                if error.isRateLimited {
                    cursorRemoteBackoffUntil = now.addingTimeInterval(10 * 60)
                }
                return error
            case .success(let fetched):
                await storeCursorRemoteUsage(fetched, accountID: session.userID, updatedAt: now)
            }
        }
        return nil
    }

    private func storeCursorRemoteUsage(
        _ fetched: CursorUsageFetchResult,
        accountID: String,
        updatedAt: Date
    ) async {
        aggregator.replaceRemote(app: .cursor, dayRange: fetched.dayRange, buckets: fetched.buckets)
        cursorUsageCache.accountID = accountID
        cursorUsageCache.buckets = aggregator.snapshotRemote(app: .cursor)
        if let range = CursorUsageDayRange(range: fetched.dayRange) {
            cursorUsageCache.coveredDayRanges = cursorUsageCache.coveredDayRanges.merged(with: range)
        }
        cursorUsageCache.updatedAt = updatedAt
        cursorRemoteUsageError = nil
        cursorRemoteBackoffUntil = nil
        publishTotals()

        let cacheSnapshot = cursorUsageCache
        do {
            try await Task.detached(priority: .utility) {
                try CursorUsageCache.save(cacheSnapshot)
            }.value
        } catch {
            // 远端内存快照仍可展示；下一轮成功刷新会再次尝试原子写缓存。
            cursorRemoteUsageError = "Cursor usage cache save failed: \(error)"
        }
    }

    private func normalizedCursorHistoryRange(
        _ range: Range<Date>,
        now: Date,
        calendar: Calendar
    ) -> Range<Date>? {
        guard range.lowerBound != .distantPast, range.upperBound != .distantFuture else {
            return nil
        }

        let start = calendar.startOfDay(for: range.lowerBound)
        let effectiveEnd = min(range.upperBound, now)
        guard start < effectiveEnd else { return nil }

        let endDay = calendar.startOfDay(for: effectiveEnd)
        let end: Date
        if effectiveEnd == endDay {
            end = endDay
        } else {
            end = calendar.date(byAdding: .day, value: 1, to: endDay) ?? effectiveEnd
        }
        return start < end ? start..<end : nil
    }

    private func cursorHistoryMonthChunks(
        for range: Range<Date>,
        calendar: Calendar
    ) -> [Range<Date>] {
        var chunks: [Range<Date>] = []
        var cursor = range.lowerBound
        while cursor < range.upperBound {
            let month = calendar.dateComponents([.year, .month], from: cursor)
            guard let monthStart = calendar.date(from: month),
                  let nextMonth = calendar.date(byAdding: .month, value: 1, to: monthStart)
            else {
                return chunks
            }
            let end = min(nextMonth, range.upperBound)
            guard cursor < end else { return chunks }
            chunks.append(cursor..<end)
            cursor = end
        }
        return chunks
    }

    /// 由 Scheduler / 手动触发；防重入。
    func scanNow() async {
        if isScanning {
            scanQueued = true
            return
        }
        isScanning = true
        defer { isScanning = false }

        repeat {
            scanQueued = false
            // 借用量扫描的既有节奏当远端价格目录 24h 到期检查的心跳，不新开定时器；非阻塞。
            PricingCatalogStore.shared.refreshIfNeeded()
            PricingCatalogStore.shared.commitPending()
            let knownUsage = pricingUsageKeys(from: aggregator.snapshotLocal())
            let cacheResult = await resolveScanState(knownUsage: knownUsage)
            if case .invalidated = cacheResult {
                clearUsageAggregatesForFullRebuild()
            }
            if await runScan(prev: cacheResult.state) {
                requiresFullRebuild = false
                if await refreshMissingPricingIfNeeded() {
                    // 已在本轮结束的安全边界提交新价格；下一轮会因指纹变化自动全量重算。
                    scanQueued = true
                }
            }
        } while scanQueued
    }

    /// 受限重建的日志回溯窗口。5h / weekly 周期滚动涉及的条目必然落在最近一个周期内，
    /// 窗口外（大于此天数）的历史归属早已固化，不需要重扫，给足余量即可。
    nonisolated private static let rebuildWindowDays = 8

    /// 周期窗口滚动 / 账号段变化后的受限重建：只重扫最近 `rebuildWindowDays` 天的日志，
    /// 仅重算受影响周期内的桶，历史桶保留。
    /// 触发频率高（5h / weekly 滚动，每天数次），必须保持轻量；
    /// 全量重建只在冷启动且 cycle rollup 无效时发生一次（见 `rebuildCycleUsageIfNeeded`）。
    func rebuildCycleUsageForRecentChanges() async {
        guard let appState, !appState.quotaCycles.records.isEmpty else { return }
        while isScanning || isCycleRebuilding {
            try? await Task.sleep(nanoseconds: 150_000_000)
        }

        isCycleRebuilding = true
        isScanning = true
        defer {
            isCycleRebuilding = false
            isScanning = false
            scanProgress = nil
            if scanQueued {
                Task { await scanNow() }
            }
        }
        // 先提交上次常规扫描之后新追加的日志，推进主 watermark。
        // 否则它们会先被下面的窗口重扫灌入，再被下一次常规增量扫描重复计入。
        guard await drainPendingUsageBeforeCycleRebuild() else { return }

        let calendar = Calendar(identifier: .gregorian)
        let now = Date()
        let rebuildWindowStart = calendar.date(
            byAdding: .day,
            value: -Self.rebuildWindowDays,
            to: now
        ) ?? now
        let cycles = appState.quotaCycles.records
        let accountSegments = appState.quotaCycles.accountSegments
        let affectedCycleIDs = Self.affectedCycleIDs(
            cycles: cycles,
            since: rebuildWindowStart,
            until: now
        )
        let dateFrom = Self.rebuildScanStart(
            windowStart: rebuildWindowStart,
            cycles: cycles,
            affectedCycleIDs: affectedCycleIDs
        )
        let home = FileManager.default.homeDirectoryForCurrentUser
        let codexRoots = [
            home.appendingPathComponent(".codex/sessions", isDirectory: true),
            home.appendingPathComponent(".codex/archived_sessions", isDirectory: true),
        ]
        let progress: ScanProgressCallback? = { [weak self] progress in
            DispatchQueue.main.async { self?.scanProgress = progress }
        }

        async let claudeTask = Task.detached(priority: .utility) {
            ClaudeJSONLScanner.scan(
                previous: [:],
                seenMessageIds: [],
                root: ClaudeJSONLScanner.defaultRoot(),
                // 重建只需要 entries，跳过标题索引构建（省一次索引文件解析）
                conversationIndex: ConversationTitleIndex.ClaudeIndex(titles: [:], projects: [:]),
                minimumMtime: dateFrom,
                onProgress: progress
            )
        }.value
        async let codexTask = Task.detached(priority: .utility) {
            await CodexJSONLScanner.scan(
                previous: [:],
                roots: codexRoots,
                indexedTitles: [:],
                minimumMtime: dateFrom,
                onProgress: progress
            )
        }.value
        let claude = await claudeTask
        let codex = await codexTask
        let affectedCycles = cycles.filter { affectedCycleIDs.contains($0.id) }
        let failedApps = Self.cycleRebuildFailedApps(
            claude: claude,
            codex: codex,
            cycles: affectedCycles
        )
        let rebuildableCycleIDs = Self.cycleRebuildableCycleIDs(
            cycles: affectedCycles,
            requestedCycleIDs: affectedCycleIDs,
            failedApps: failedApps
        )
        await commitCycleAggregation(
            exactEntries: (claude.entries + codex.entries).filter { !failedApps.contains($0.app) },
            cycles: cycles,
            accountSegments: accountSegments,
            failedApps: failedApps,
            rebuildRange: rebuildableCycleIDs
        )
    }

    /// 返回与重建扫描区间相交的周期。周期可能开始于 dateFrom 之前、结束于其后，
    /// 这类跨界周期同样会接收到本轮扫描条目，必须先清桶再重灌。
    nonisolated static func affectedCycleIDs(
        cycles: [QuotaCycleRecord],
        since dateFrom: Date,
        until dateTo: Date
    ) -> Set<String> {
        Set(cycles.filter {
            $0.endAt > dateFrom && $0.startAt < dateTo
        }.map(\.id))
    }

    /// 清桶前必须扫到受影响周期的真实起点，避免跨窗口周期只灌回后半段。
    nonisolated static func rebuildScanStart(
        windowStart: Date,
        cycles: [QuotaCycleRecord],
        affectedCycleIDs: Set<String>
    ) -> Date {
        cycles.lazy
            .filter { affectedCycleIDs.contains($0.id) }
            .map(\.startAt)
            .reduce(windowStart, min)
    }

    /// 只有根目录或文件实际读取失败才冻结对应 Provider；目录从未存在表示本机没有
    /// 该 Provider 的日志，是可成功重建为空的正常状态，不能阻塞另一侧。
    nonisolated static func cycleRebuildFailedApps(
        claude: ClaudeJSONLScanner.Result?,
        codex: CodexJSONLScanner.Result?,
        cycles: [QuotaCycleRecord]
    ) -> Set<UsageApp> {
        let apps = Set(cycles.map(\.app))
        var failedApps: Set<UsageApp> = []
        if apps.contains(.claude), let claude, claude.failedFileCount > 0 {
            failedApps.insert(.claude)
        }
        if apps.contains(.codex), let codex, codex.failedFileCount > 0 {
            failedApps.insert(.codex)
        }
        return failedApps
    }

    nonisolated static func pendingInitialCycleRebuildApps(
        cycles: [QuotaCycleRecord],
        completedApps: Set<UsageApp>
    ) -> Set<UsageApp> {
        Set(cycles.map(\.app))
            .intersection([.codex, .claude])
            .subtracting(completedApps)
    }

    nonisolated static func updatedInitialCycleRebuildApps(
        completedApps: Set<UsageApp>,
        requestedApps: Set<UsageApp>,
        failedApps: Set<UsageApp>
    ) -> Set<UsageApp> {
        completedApps.union(requestedApps.subtracting(failedApps))
    }

    /// 读取失败时只排除对应 Provider 的周期，保留其已有桶；其余 Provider 继续清桶重灌。
    nonisolated static func cycleRebuildableCycleIDs(
        cycles: [QuotaCycleRecord],
        requestedCycleIDs: Set<String>,
        failedApps: Set<UsageApp>
    ) -> Set<String> {
        Set(cycles.lazy
            .filter { requestedCycleIDs.contains($0.id) && !failedApps.contains($0.app) }
            .map(\.id))
    }

    /// 周期重建只能覆盖或清除自己产生的错误，不能抹掉前置增量扫描刚发现的告警。
    nonisolated static func lastErrorAfterCycleRebuild(
        current: String?,
        rebuildWarning: String?
    ) -> String? {
        if let rebuildWarning { return rebuildWarning }
        if current?.hasPrefix("cycle usage rebuild") == true { return nil }
        return current
    }

    /// 受限重建前用主扫描状态做一次常规增量提交，保证窗口重扫后
    /// watermark 不会再返回同一批条目。失效状态沿用常规扫描的全量重建语义。
    private func drainPendingUsageBeforeCycleRebuild() async -> Bool {
        let knownUsage = pricingUsageKeys(from: aggregator.snapshotLocal())
        let cacheResult = await resolveScanState(knownUsage: knownUsage)
        if case .invalidated = cacheResult {
            clearUsageAggregatesForFullRebuild()
        }
        guard await runScan(prev: cacheResult.state) else { return false }
        requiresFullRebuild = false
        return true
    }

    private func clearUsageAggregatesForFullRebuild() {
        cachedScanState = nil
        aggregator.load(from: [])
        conversationAggregator.load(infos: [], buckets: [])
        cycleAggregator.load(from: [])
        loadedRollupGeneration = nil
        loadedCycleGeneration = nil
        cycleInitialRebuildCompletedAt = nil
        cycleInitialRebuildCompletedApps = []
        publishTotals()
    }

    /// 周期用量重建的公共收尾：聚合 → 落盘 rollup → 更新内存状态。
    /// - Parameter initialRebuildApps: 本轮执行初始重建的 Provider；成功侧会独立置位，
    ///   失败侧保持待重试，不会让已完成 Provider 在下次启动重复全量扫描。
    /// - Parameter rebuildRange: 非 nil 表示受限重建，只重算这些周期内的桶。
    private func commitCycleAggregation(
        exactEntries: [UsageEntry],
        cycles: [QuotaCycleRecord],
        accountSegments: [QuotaCycleAccountSegment],
        initialRebuildApps: Set<UsageApp> = [],
        failedApps: Set<UsageApp> = [],
        rebuildRange affectedCycleIDs: Set<String>? = nil
    ) async {
        let failedProviderNames = [UsageApp.codex, .claude]
            .filter { failedApps.contains($0) }
            .map { $0 == .codex ? "Codex" : "Claude Code" }
            .joined(separator: ", ")
        let rebuildWarning = failedApps.isEmpty
            ? nil
            : "cycle usage rebuild incomplete: \(failedProviderNames) logs unreadable; previous data preserved"
        if let affectedCycleIDs, affectedCycleIDs.isEmpty, !failedApps.isEmpty {
            lastError = rebuildWarning
            print("[CycleUsage 周期用量] rebuild deferred providers=\(failedProviderNames)")
            return
        }
        let started = Date()
        if let affectedCycleIDs {
            cycleAggregator.rebuildRange(
                exactEntries: exactEntries,
                cycles: cycles,
                accountSegments: accountSegments,
                affectedCycleIDs: affectedCycleIDs
            )
        } else {
            cycleAggregator.rebuild(
                exactEntries: exactEntries,
                cycles: cycles,
                accountSegments: accountSegments
            )
        }
        let completedAt = Date()
        let completedApps = Self.updatedInitialCycleRebuildApps(
            completedApps: cycleInitialRebuildCompletedApps,
            requestedApps: initialRebuildApps,
            failedApps: failedApps
        )
        let requiredApps = Set(cycles.map(\.app)).intersection([.codex, .claude])
        let completedInitialRebuild = !initialRebuildApps.isEmpty
            && !requiredApps.isEmpty
            && completedApps.isSuperset(of: requiredApps)
        let generationID = loadedRollupGeneration ?? UUID().uuidString
        let fingerprint = Pricing.fingerprint(knownUsage: pricingUsageKeys(from: aggregator.snapshotLocal()))
        let rollup = CycleUsageRollupPayload(
            generationID: generationID,
            pricingFingerprint: fingerprint,
            buckets: cycleAggregator.snapshot(),
            initialRebuildCompletedAt: completedInitialRebuild ? completedAt : cycleInitialRebuildCompletedAt,
            initialRebuildCompletedApps: completedApps,
            updatedAt: completedAt
        )
        do {
            try await Task.detached(priority: .utility) {
                try CycleUsageRollupCache.save(rollup)
            }.value
            loadedCycleGeneration = generationID
            cycleInitialRebuildCompletedApps = completedApps
            if completedInitialRebuild {
                cycleInitialRebuildCompletedAt = completedAt
            }
            lastError = Self.lastErrorAfterCycleRebuild(
                current: lastError,
                rebuildWarning: rebuildWarning
            )
            let elapsed = String(format: "%.2fs", Date().timeIntervalSince(started))
            let tag = initialRebuildApps.isEmpty ? "range rebuild" : "initial rebuild"
            let status = failedApps.isEmpty ? "completed" : "partially completed"
            print("[CycleUsage 周期用量] \(tag) \(status) elapsed=\(elapsed)")
        } catch {
            lastError = "cycle usage rebuild failed: \(error)"
            print("[CycleUsage 周期用量] cycle usage rebuild failed: \(error)")
        }
    }

    func rebuildCycleUsageIfNeeded() async {
        guard let appState, !appState.quotaCycles.records.isEmpty else { return }
        guard !Self.pendingInitialCycleRebuildApps(
            cycles: appState.quotaCycles.records,
            completedApps: cycleInitialRebuildCompletedApps
        ).isEmpty else { return }
        while isScanning || isCycleRebuilding {
            try? await Task.sleep(nanoseconds: 150_000_000)
            if Self.pendingInitialCycleRebuildApps(
                cycles: appState.quotaCycles.records,
                completedApps: cycleInitialRebuildCompletedApps
            ).isEmpty { return }
        }

        isCycleRebuilding = true
        isScanning = true
        defer {
            isCycleRebuilding = false
            isScanning = false
            scanProgress = nil
            if scanQueued {
                Task { await scanNow() }
            }
        }
        let progress: ScanProgressCallback? = { [weak self] progress in
            DispatchQueue.main.async { self?.scanProgress = progress }
        }
        let cycles = appState.quotaCycles.records
        let pendingApps = Self.pendingInitialCycleRebuildApps(
            cycles: cycles,
            completedApps: cycleInitialRebuildCompletedApps
        )
        guard !pendingApps.isEmpty else { return }
        let claudeTask: Task<ClaudeJSONLScanner.Result, Never>? = pendingApps.contains(.claude)
            ? Task.detached(priority: .utility) {
                ClaudeJSONLScanner.scan(
                    previous: [:],
                    seenMessageIds: [],
                    onProgress: progress
                )
            }
            : nil
        let codexTask: Task<CodexJSONLScanner.Result, Never>? = pendingApps.contains(.codex)
            ? Task.detached(priority: .utility) {
                await CodexJSONLScanner.scan(previous: [:], onProgress: progress)
            }
            : nil
        let claude = await claudeTask?.value
        let codex = await codexTask?.value
        let pendingCycles = cycles.filter { pendingApps.contains($0.app) }
        let failedApps = Self.cycleRebuildFailedApps(
            claude: claude,
            codex: codex,
            cycles: pendingCycles
        )
        let pendingCycleIDs = Set(pendingCycles.map(\.id))
        let rebuildableCycleIDs = Self.cycleRebuildableCycleIDs(
            cycles: pendingCycles,
            requestedCycleIDs: pendingCycleIDs,
            failedApps: failedApps
        )
        await commitCycleAggregation(
            exactEntries: ((claude?.entries ?? []) + (codex?.entries ?? []))
                .filter { !failedApps.contains($0.app) },
            cycles: cycles,
            accountSegments: appState.quotaCycles.accountSegments,
            initialRebuildApps: pendingApps,
            failedApps: failedApps,
            rebuildRange: rebuildableCycleIDs
        )
    }

    /// 决定本轮扫描的起点状态。优先用内存里上一轮已提交的 ScanState；
    /// 内存路径与磁盘路径执行同样的校验——generationID 须与已加载 rollup 同代、
    /// 价格指纹须与当前 active 价格目录一致（commitPending 提交新价格后指纹变化，
    /// 照旧触发全量重建）。只有冷启动且日聚合、对话两份主 rollup 恢复成功时，
    /// 首轮需要读盘取得与它们同代的 ScanState。
    private func resolveScanState(knownUsage: Set<PricingUsageKey>) async -> ScanCacheLoadResult {
        if requiresFullRebuild { return .invalidated }
        if let cached = cachedScanState {
            if cached.generationID == loadedRollupGeneration,
               cached.pricingFingerprint == Pricing.fingerprint(knownUsage: knownUsage) {
                return .valid(cached)
            }
            return .invalidated
        }
        let loaded = await Task.detached(priority: .utility) {
            ScanCache.load(knownUsage: knownUsage)
        }.value
        if case .valid(let state) = loaded, state.generationID == loadedRollupGeneration {
            return loaded
        }
        return .invalidated
    }

    /// 用户在设置页手动触发的强制重算：无视已有 watermark 和 fingerprint，
    /// 清空内存聚合并把本地全部日志按当前已提交的价格目录重新解析、重新计费。
    /// 用于「定价表改错后修复，想立刻重算」这类场景，不必等下次价格表变动或重启 App。
    func forceRescan() async {
        // 撞上另一次进行中的扫描(常见于 App 冷启动自动扫描、或 Scheduler 定时扫描)时,
        // 不再静默丢弃这次操作:等它跑完再真正强制重算,保证用户点的这次一定生效。
        // 设置页按钮的 spinner 在等待期间会一直转,用户感知不到差异,只是变"诚实"了。
        while isScanning {
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        isScanning = true
        defer {
            isScanning = false
            scanProgress = nil
        }
        PricingCatalogStore.shared.refreshIfNeeded()
        // 手动重算同样是一次完整扫描：先提交已经刷好的 pending，避免用户刚点击重算
        // 却仍按旧 active 价格扫描；本次刚发起的网络刷新则留给下一次扫描。
        PricingCatalogStore.shared.commitPending()
        cachedScanState = nil
        aggregator.load(from: [])
        conversationAggregator.load(infos: [], buckets: [])
        cycleAggregator.load(from: [])
        loadedRollupGeneration = nil
        loadedCycleGeneration = nil
        cycleInitialRebuildCompletedAt = nil
        cycleInitialRebuildCompletedApps = []
        publishTotals()
        requiresFullRebuild = true
        if await runScan(prev: ScanState(), reportProgress: true) {
            requiresFullRebuild = false
            if await refreshMissingPricingIfNeeded() {
                // 强制重算没有 scanNow 的 repeat 循环；缺价刷新拿到新价格后就在这里
                // 立即再做一次全量扫描，避免必须等待下一次定时扫描。
                cachedScanState = nil
                aggregator.load(from: [])
                conversationAggregator.load(infos: [], buckets: [])
                cycleAggregator.load(from: [])
                loadedRollupGeneration = nil
                loadedCycleGeneration = nil
                publishTotals()
                requiresFullRebuild = true
                if await runScan(prev: ScanState(), reportProgress: true) {
                    requiresFullRebuild = false
                }
            }
        }
    }

    /// 设置页手动更新在线价格目录：绕过 24 小时，到扫描安全边界提交并按需重算。
    @discardableResult
    func refreshPricingCatalog() async -> Bool {
        guard !isRefreshingPricingCatalog else { return false }
        isRefreshingPricingCatalog = true
        defer { isRefreshingPricingCatalog = false }
        let succeeded = await PricingCatalogStore.shared.forceRefresh()
        guard succeeded else { return false }
        await scanNow()
        return true
    }

    @discardableResult
    private func runScan(prev: ScanState, reportProgress: Bool = false) async -> Bool {
        let started = Date()
        let prevSeen = prev.claudeSeenMessageIds
        let progress: ScanProgressCallback?
        if reportProgress {
            progress = { [weak self] (p: ScanProgress) in
                DispatchQueue.main.async {
                    self?.scanProgress = p
                }
            }
        } else {
            progress = nil
        }
        async let claudeTask = Task.detached(priority: .utility) {
            ClaudeJSONLScanner.scan(
                previous: prev.claude,
                seenMessageIds: prevSeen,
                onProgress: progress
            )
        }.value
        async let codexTask = Task.detached(priority: .utility) {
            await CodexJSONLScanner.scan(previous: prev.codex, onProgress: progress)
        }.value
        async let piTask = Task.detached(priority: .utility) {
            PiJSONLScanner.scan(
                previous: prev.pi,
                seenEntryIds: prev.piSeenEntryIds,
                onProgress: progress
            )
        }.value
        async let opencodeTask = Task.detached(priority: .utility) {
            OpencodeScanner.scan(
                lastMessageTime: prev.opencodeLastMessageTime,
                seenMessageIds: prev.opencodeSeenMessageIds,
                onProgress: progress
            )
        }.value

        let claude = await claudeTask
        let codex = await codexTask
        let pi = await piTask
        let opencode = await opencodeTask
        let failedFileCount = claude.failedFileCount + codex.failedFileCount

        aggregator.ingestLocal(claude.entries)
        aggregator.ingestLocal(codex.entries)
        aggregator.ingestLocal(pi.entries)
        aggregator.ingestLocal(opencode.entries)
        let cycleEntries = claude.entries + codex.entries
        let conversationChanged = conversationAggregator.ingest(
            entries: claude.entries + codex.entries + pi.entries + opencode.entries,
            seeds: claude.conversationSeeds + codex.conversationSeeds + pi.conversationSeeds + opencode.conversationSeeds
        )

        // 个人历史用量一次性补录：缓存失效路径会清空聚合器，若只在 bootstrap 合并，
        // 这里落盘的 rollup / 指纹将不含补录模型，下次启动指纹比对再失效、补录被反复冲掉。
        // 每轮扫描都按天去重重新合并，保证快照与指纹始终包含补录数据。
        let existingClaudeDays = Set(aggregator.snapshotLocal().filter { $0.app == .claude }.map(\.day))
        aggregator.ingestLocal(ImportedUsageBackfill.loadMissingEntries(app: .claude, existingDays: existingClaudeDays))

        let cycles = appState?.quotaCycles.records ?? []
        let cycleChanged: Bool
        if prev.generationID.isEmpty, !cycles.isEmpty {
            let initialApps = Self.pendingInitialCycleRebuildApps(
                cycles: cycles,
                completedApps: cycleInitialRebuildCompletedApps
            )
            let initialCycles = cycles.filter { initialApps.contains($0.app) }
            let failedApps = Self.cycleRebuildFailedApps(
                claude: claude,
                codex: codex,
                cycles: initialCycles
            )
            let initialCycleIDs = Set(initialCycles.map(\.id))
            let rebuildableCycleIDs = Self.cycleRebuildableCycleIDs(
                cycles: initialCycles,
                requestedCycleIDs: initialCycleIDs,
                failedApps: failedApps
            )
            cycleAggregator.rebuildRange(
                exactEntries: cycleEntries.filter { !failedApps.contains($0.app) },
                cycles: cycles,
                accountSegments: appState?.quotaCycles.accountSegments ?? [],
                affectedCycleIDs: rebuildableCycleIDs
            )
            cycleInitialRebuildCompletedApps = Self.updatedInitialCycleRebuildApps(
                completedApps: cycleInitialRebuildCompletedApps,
                requestedApps: initialApps,
                failedApps: failedApps
            )
            let requiredApps = Set(cycles.map(\.app)).intersection([.codex, .claude])
            if cycleInitialRebuildCompletedApps.isSuperset(of: requiredApps) {
                cycleInitialRebuildCompletedAt = Date()
            }
            cycleChanged = true
        } else {
            cycleChanged = cycleAggregator.ingest(
                entries: cycleEntries,
                cycles: cycles,
                accountSegments: appState?.quotaCycles.accountSegments ?? []
            )
        }

        // 没有真实用量或档案变化时沿用现有代次，只提交轻量 watermark。
        let buckets = aggregator.snapshotLocal()
        let fingerprint = Pricing.fingerprint(knownUsage: pricingUsageKeys(from: buckets))
        let hasNewEntries = !claude.entries.isEmpty || !codex.entries.isEmpty || !pi.entries.isEmpty || !opencode.entries.isEmpty
        let shouldWriteRollups = loadedRollupGeneration == nil || hasNewEntries || conversationChanged
        let generationID = shouldWriteRollups ? UUID().uuidString : loadedRollupGeneration!
        let newScanState = ScanState(
            generationID: generationID,
            pricingFingerprint: fingerprint,
            claude: claude.newState,
            codex: codex.newState,
            claudeSeenMessageIds: claude.newSeenIds,
            pi: pi.newState,
            piSeenEntryIds: pi.newSeenIds,
            opencodeLastMessageTime: opencode.newLastMessageTime,
            opencodeSeenMessageIds: opencode.newSeenMessageIds
        )
        let shouldWriteScanState = newScanState != prev

        let rollup: UsageRollupPayload?
        let conversationRollup: ConversationRollupPayload?
        let cycleRollup: CycleUsageRollupPayload?
        if shouldWriteRollups {
            let updatedAt = Date()
            let conversationSnapshot = conversationAggregator.snapshot()
            rollup = UsageRollupPayload(
                generationID: generationID,
                pricingFingerprint: fingerprint,
                buckets: buckets,
                updatedAt: updatedAt
            )
            conversationRollup = ConversationRollupPayload(
                generationID: generationID,
                pricingFingerprint: fingerprint,
                infos: conversationSnapshot.infos,
                buckets: conversationSnapshot.buckets,
                updatedAt: updatedAt
            )
            cycleRollup = CycleUsageRollupPayload(
                generationID: generationID,
                pricingFingerprint: fingerprint,
                buckets: cycleAggregator.snapshot(),
                initialRebuildCompletedAt: cycleInitialRebuildCompletedAt,
                initialRebuildCompletedApps: cycleInitialRebuildCompletedApps,
                updatedAt: updatedAt
            )
        } else {
            rollup = nil
            conversationRollup = nil
            if cycleChanged || loadedCycleGeneration == nil {
                cycleRollup = CycleUsageRollupPayload(
                    generationID: generationID,
                    pricingFingerprint: fingerprint,
                    buckets: cycleAggregator.snapshot(),
                    initialRebuildCompletedAt: cycleInitialRebuildCompletedAt,
                    initialRebuildCompletedApps: cycleInitialRebuildCompletedApps,
                    updatedAt: Date()
                )
            } else {
                cycleRollup = nil
            }
        }

        let persistenceError: String? = await Task.detached(priority: .utility) {
            do {
                if let rollup, let conversationRollup {
                    // 聚合结果先落盘，watermark 最后提交；generationID 用于启动时识别中断写入。
                    try UsageRollupCache.save(rollup)
                    try ConversationRollupCache.save(conversationRollup)
                }
                if let cycleRollup {
                    try CycleUsageRollupCache.save(cycleRollup)
                }
                if shouldWriteScanState {
                    try ScanCache.save(newScanState)
                }
                return nil
            } catch {
                let saveError = error
                do {
                    try ScanCache.invalidate()
                } catch {
                    return "\(saveError); scan-state invalidate failed: \(error)"
                }
                return String(describing: saveError)
            }
        }.value

        if let persistenceError {
            requiresFullRebuild = true
            cachedScanState = nil
            lastError = persistenceError
            print("[UsageScan 用量扫描] 持久化失败 persistence failed: \(persistenceError)")
            return false
        }

        loadedRollupGeneration = generationID
        if cycleRollup != nil {
            loadedCycleGeneration = generationID
        }
        cachedScanState = newScanState
        lastScanAt = Date()
        lastError = failedFileCount > 0
            ? "usage scan incomplete: \(failedFileCount) log source(s) unreadable; retrying next scan"
            : nil
        publishTotals()

        let elapsed = String(format: "%.2fs", Date().timeIntervalSince(started))
        print("[UsageScan 用量扫描] claude files=\(claude.filesScanned) lines=\(claude.linesParsed) new=\(claude.entries.count); codex files=\(codex.filesScanned) lines=\(codex.linesParsed) new=\(codex.entries.count); pi files=\(pi.filesScanned) lines=\(pi.linesParsed) new=\(pi.entries.count); opencode messages=\(opencode.messagesRead) new=\(opencode.entries.count); unreadable=\(failedFileCount); elapsed=\(elapsed)")
        return true
    }

    /// 只把“已有 Standard/Fast 用量但当前所有可靠价格源都未命中”的桶视为刷新候选。
    /// Unknown 档位和已知模型的请求级限制（例如 Codex Fast >272K）不会造成无休止刷新。
    private func refreshMissingPricingIfNeeded() async -> Bool {
        let buckets = aggregator.snapshotLocal()
        let missing = Set(buckets.compactMap { bucket -> PricingUsageKey? in
            guard bucket.hasUnpricedUsage else { return nil }
            guard Pricing.needsRemotePriceRefresh(
                model: bucket.model,
                app: bucket.app,
                speed: bucket.speed
            ) else { return nil }
            return PricingUsageKey(app: bucket.app, model: bucket.model, speed: bucket.speed)
        })
        guard !missing.isEmpty else { return false }

        let knownUsage = pricingUsageKeys(from: buckets)
        let before = Pricing.fingerprint(knownUsage: knownUsage)
        guard await PricingCatalogStore.shared.refreshForMissing(missing) else { return false }
        PricingCatalogStore.shared.commitPending()
        let after = Pricing.fingerprint(knownUsage: knownUsage)
        return before != after
    }

    private func pricingUsageKeys(from buckets: [UsageBucket]) -> Set<PricingUsageKey> {
        Set(buckets.map {
            PricingUsageKey(app: $0.app, model: $0.model, speed: $0.speed)
        })
    }

    private func publishTotals() {
        guard let appState else { return }
        appState.codexTodayCost = aggregator.todayCost(for: .codex)
        appState.claudeTodayCost = aggregator.todayCost(for: .claude)
        appState.cursorTodayCost = aggregator.todayCost(for: .cursor)
        appState.piTodayCost = aggregator.todayCost(for: .pi)
        appState.opencodeTodayCost = aggregator.todayCost(for: .opencode)
    }
}
