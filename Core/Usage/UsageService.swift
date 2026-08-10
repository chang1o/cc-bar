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
        let (payload, conversationPayload, cyclePayload) = await Task.detached(priority: .utility) {
            (
                UsageRollupCache.load(),
                ConversationRollupCache.load(),
                CycleUsageRollupCache.load()
            )
        }.value
        let generationsMatch = !payload.generationID.isEmpty
            && payload.generationID == conversationPayload.generationID
        if generationsMatch {
            aggregator.load(from: payload.buckets)
            conversationAggregator.load(infos: conversationPayload.infos, buckets: conversationPayload.buckets)
            loadedRollupGeneration = payload.generationID
            if cyclePayload.generationID == payload.generationID,
               cyclePayload.pricingFingerprint == payload.pricingFingerprint {
                cycleAggregator.load(from: cyclePayload.buckets)
                loadedCycleGeneration = cyclePayload.generationID
                cycleInitialRebuildCompletedAt = cyclePayload.initialRebuildCompletedAt
            } else {
                cycleAggregator.load(from: [])
                loadedCycleGeneration = nil
                cycleInitialRebuildCompletedAt = nil
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
            lastScanAt = nil
        }
        // 个人历史用量一次性补录：见 ImportedUsageBackfill 注释。这里先合并一次保证扫描前即可展示；
        // runScan 每轮还会按同样规则重新合并，兜底缓存失效清空聚合器的情况。文件不存在时是纯 no-op。
        let existingClaudeDays = Set(aggregator.snapshot().filter { $0.app == .claude }.map(\.day))
        aggregator.ingest(ImportedUsageBackfill.loadMissingEntries(app: .claude, existingDays: existingClaudeDays))
        publishTotals()
        // 远端价格目录后台刷新：非阻塞，isDue 内部判断是否真的需要发请求，刷新结果由下次扫描自然拾取。
        PricingCatalogStore.shared.refreshIfNeeded()
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
            let knownUsage = pricingUsageKeys(from: aggregator.snapshot())
            let cacheResult = await resolveScanState(knownUsage: knownUsage)
            if case .invalidated = cacheResult {
                cachedScanState = nil
                aggregator.load(from: [])
                conversationAggregator.load(infos: [], buckets: [])
                cycleAggregator.load(from: [])
                loadedRollupGeneration = nil
                loadedCycleGeneration = nil
                cycleInitialRebuildCompletedAt = nil
                publishTotals()
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
        let calendar = Calendar(identifier: .gregorian)
        let now = Date()
        let dateFrom = calendar.date(
            byAdding: .day,
            value: -Self.rebuildWindowDays,
            to: now
        ) ?? now
        let cycles = appState.quotaCycles.records
        let accountSegments = appState.quotaCycles.accountSegments
        let affectedCycleIDs = Set(cycles.filter { $0.startAt >= dateFrom }.map(\.id))
        let codexRoots = Self.codexRoots(since: dateFrom, calendar: calendar, now: now)
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
                onProgress: progress
            )
        }.value
        let claude = await claudeTask
        let codex = await codexTask
        await commitCycleAggregation(
            exactEntries: claude.entries + codex.entries,
            cycles: cycles,
            accountSegments: accountSegments,
            isInitialRebuild: false,
            rebuildRange: affectedCycleIDs
        )
    }

    /// 最近 `rebuildWindowDays` 天按 codex 的 `sessions/YYYY/MM/DD` 目录结构构造 root 列表。
    /// 目录全不存在（路径结构变化）时回退默认全量 roots，避免重建静默变空。
    nonisolated private static func codexRoots(
        since dateFrom: Date,
        calendar: Calendar,
        now: Date
    ) -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let baseRoots = [
            home.appendingPathComponent(".codex/sessions", isDirectory: true),
            home.appendingPathComponent(".codex/archived_sessions", isDirectory: true),
        ]
        let fm = FileManager.default
        var roots: [URL] = []
        let days = max(0, calendar.dateComponents([.day], from: dateFrom, to: now).day ?? 0)
        for dayOffset in (0...days).reversed() {
            guard let day = calendar.date(byAdding: .day, value: -dayOffset, to: now) else { continue }
            let comps = calendar.dateComponents([.year, .month, .day], from: day)
            guard let year = comps.year, let month = comps.month, let day = comps.day else { continue }
            for base in baseRoots {
                let dir = base
                    .appendingPathComponent(String(format: "%04d", year), isDirectory: true)
                    .appendingPathComponent(String(format: "%02d", month), isDirectory: true)
                    .appendingPathComponent(String(format: "%02d", day), isDirectory: true)
                if fm.fileExists(atPath: dir.path) {
                    roots.append(dir)
                }
            }
        }
        return roots.isEmpty ? baseRoots : roots
    }

    /// 周期用量重建的公共收尾：聚合 → 落盘 rollup → 更新内存状态。
    /// - Parameter isInitialRebuild: true 表示冷启动全量重建（完成后标记"初始重建完成"，
    ///   该标记只有全量重建能置位，受限重建保持现值，确保聚合器未初始化时不会被跳过）。
    /// - Parameter rebuildRange: 非 nil 表示受限重建，只重算这些周期内的桶。
    private func commitCycleAggregation(
        exactEntries: [UsageEntry],
        cycles: [QuotaCycleRecord],
        accountSegments: [QuotaCycleAccountSegment],
        isInitialRebuild: Bool,
        rebuildRange affectedCycleIDs: Set<String>? = nil
    ) async {
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
        let generationID = loadedRollupGeneration ?? UUID().uuidString
        let fingerprint = Pricing.fingerprint(knownUsage: pricingUsageKeys(from: aggregator.snapshot()))
        let rollup = CycleUsageRollupPayload(
            generationID: generationID,
            pricingFingerprint: fingerprint,
            buckets: cycleAggregator.snapshot(),
            initialRebuildCompletedAt: isInitialRebuild ? completedAt : cycleInitialRebuildCompletedAt,
            updatedAt: completedAt
        )
        do {
            try await Task.detached(priority: .utility) {
                try CycleUsageRollupCache.save(rollup)
            }.value
            loadedCycleGeneration = generationID
            if isInitialRebuild {
                cycleInitialRebuildCompletedAt = completedAt
            }
            let elapsed = String(format: "%.2fs", Date().timeIntervalSince(started))
            let tag = isInitialRebuild ? "initial rebuild" : "range rebuild"
            print("[CycleUsage 周期用量] \(tag) completed elapsed=\(elapsed)")
        } catch {
            lastError = "cycle usage rebuild failed: \(error)"
            print("[CycleUsage 周期用量] cycle usage rebuild failed: \(error)")
        }
    }

    func rebuildCycleUsageIfNeeded() async {
        guard cycleInitialRebuildCompletedAt == nil else { return }
        guard let appState, !appState.quotaCycles.records.isEmpty else { return }
        while isScanning || isCycleRebuilding {
            try? await Task.sleep(nanoseconds: 150_000_000)
            if cycleInitialRebuildCompletedAt != nil { return }
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
        async let claudeTask = Task.detached(priority: .utility) {
            ClaudeJSONLScanner.scan(
                previous: [:],
                seenMessageIds: [],
                onProgress: progress
            )
        }.value
        async let codexTask = Task.detached(priority: .utility) {
            await CodexJSONLScanner.scan(previous: [:], onProgress: progress)
        }.value
        let claude = await claudeTask
        let codex = await codexTask
        await commitCycleAggregation(
            exactEntries: claude.entries + codex.entries,
            cycles: appState.quotaCycles.records,
            accountSegments: appState.quotaCycles.accountSegments,
            isInitialRebuild: true
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

        aggregator.ingest(claude.entries)
        aggregator.ingest(codex.entries)
        aggregator.ingest(pi.entries)
        aggregator.ingest(opencode.entries)
        let cycleEntries = claude.entries + codex.entries
        let conversationChanged = conversationAggregator.ingest(
            entries: claude.entries + codex.entries + pi.entries + opencode.entries,
            seeds: claude.conversationSeeds + codex.conversationSeeds + pi.conversationSeeds + opencode.conversationSeeds
        )

        // 个人历史用量一次性补录：缓存失效路径会清空聚合器，若只在 bootstrap 合并，
        // 这里落盘的 rollup / 指纹将不含补录模型，下次启动指纹比对再失效、补录被反复冲掉。
        // 每轮扫描都按天去重重新合并，保证快照与指纹始终包含补录数据。
        let existingClaudeDays = Set(aggregator.snapshot().filter { $0.app == .claude }.map(\.day))
        aggregator.ingest(ImportedUsageBackfill.loadMissingEntries(app: .claude, existingDays: existingClaudeDays))

        let cycles = appState?.quotaCycles.records ?? []
        let cycleChanged: Bool
        if prev.generationID.isEmpty, !cycles.isEmpty {
            cycleAggregator.rebuild(
                exactEntries: cycleEntries,
                cycles: cycles,
                accountSegments: appState?.quotaCycles.accountSegments ?? []
            )
            cycleInitialRebuildCompletedAt = Date()
            cycleChanged = true
        } else {
            cycleChanged = cycleAggregator.ingest(
                entries: cycleEntries,
                cycles: cycles,
                accountSegments: appState?.quotaCycles.accountSegments ?? []
            )
        }

        // 没有真实用量或档案变化时沿用现有代次，只提交轻量 watermark。
        let buckets = aggregator.snapshot()
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
        lastError = nil
        publishTotals()

        let elapsed = String(format: "%.2fs", Date().timeIntervalSince(started))
        print("[UsageScan 用量扫描] claude files=\(claude.filesScanned) lines=\(claude.linesParsed) new=\(claude.entries.count); codex files=\(codex.filesScanned) lines=\(codex.linesParsed) new=\(codex.entries.count); pi files=\(pi.filesScanned) lines=\(pi.linesParsed) new=\(pi.entries.count); opencode messages=\(opencode.messagesRead) new=\(opencode.entries.count); elapsed=\(elapsed)")
        return true
    }

    /// 只把“已有 Standard/Fast 用量但当前所有可靠价格源都未命中”的桶视为刷新候选。
    /// Unknown 档位和已知模型的请求级限制（例如 Codex Fast >272K）不会造成无休止刷新。
    private func refreshMissingPricingIfNeeded() async -> Bool {
        let buckets = aggregator.snapshot()
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
        appState.piTodayCost = aggregator.todayCost(for: .pi)
        appState.opencodeTodayCost = aggregator.todayCost(for: .opencode)
    }
}
