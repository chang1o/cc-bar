import Foundation
import Observation

/// 协调 JSONL 扫描 → 聚合 → 持久化 → 通知 AppState 的入口。
@MainActor
@Observable
final class UsageService {
    let aggregator = UsageAggregator()
    let conversationAggregator = ConversationAggregator()
    private(set) var isScanning = false
    private(set) var lastScanAt: Date?
    private(set) var lastError: String?

    private weak var appState: AppState?
    private var scanQueued = false
    private var requiresFullRebuild = false
    private var loadedRollupGeneration: String?

    func bootstrap(appState: AppState) {
        self.appState = appState
        // 只有两份 rollup 同代才允许恢复，避免部分写入后把旧桶和新 watermark 混用。
        let payload = UsageRollupCache.load()
        let conversationPayload = ConversationRollupCache.load()
        let generationsMatch = !payload.generationID.isEmpty
            && payload.generationID == conversationPayload.generationID
        if generationsMatch {
            aggregator.load(from: payload.buckets)
            conversationAggregator.load(infos: conversationPayload.infos, buckets: conversationPayload.buckets)
            loadedRollupGeneration = payload.generationID
            lastScanAt = max(payload.updatedAt, conversationPayload.updatedAt)
        } else {
            aggregator.load(from: [])
            conversationAggregator.load(infos: [], buckets: [])
            requiresFullRebuild = true
            loadedRollupGeneration = nil
            lastScanAt = nil
        }
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
            let knownModels = Set(aggregator.snapshot().map { $0.model })
            let loadedCache = requiresFullRebuild
                ? ScanCacheLoadResult.invalidated
                : await Task.detached(priority: .utility) {
                    ScanCache.load(knownModels: knownModels)
                }.value
            let cacheResult: ScanCacheLoadResult
            if case .valid(let state) = loadedCache,
               state.generationID == loadedRollupGeneration {
                cacheResult = loadedCache
            } else {
                cacheResult = .invalidated
            }
            if case .invalidated = cacheResult {
                aggregator.load(from: [])
                conversationAggregator.load(infos: [], buckets: [])
                loadedRollupGeneration = nil
                publishTotals()
            }
            if await runScan(prev: cacheResult.state) {
                requiresFullRebuild = false
            }
        } while scanQueued
    }

    /// 用户在设置页手动触发的强制重算：无视已有 watermark 和 fingerprint，
    /// 清空内存聚合并把本地全部日志按当前已提交的价格目录重新解析、重新计费。
    /// 用于「定价表改错后修复，想立刻重算」这类场景，不必等下次价格表变动或重启 App。
    func forceRescan() async {
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false }
        PricingCatalogStore.shared.refreshIfNeeded()
        // 手动重算同样是一次完整扫描：先提交已经刷好的 pending，避免用户刚点击重算
        // 却仍按旧 active 价格扫描；本次刚发起的网络刷新则留给下一次扫描。
        PricingCatalogStore.shared.commitPending()
        aggregator.load(from: [])
        conversationAggregator.load(infos: [], buckets: [])
        loadedRollupGeneration = nil
        publishTotals()
        requiresFullRebuild = true
        if await runScan(prev: ScanState()) {
            requiresFullRebuild = false
        }
    }

    @discardableResult
    private func runScan(prev: ScanState) async -> Bool {
        let started = Date()
        let prevSeen = prev.claudeSeenMessageIds
        async let claudeTask = Task.detached(priority: .utility) {
            ClaudeJSONLScanner.scan(previous: prev.claude, seenMessageIds: prevSeen)
        }.value
        async let codexTask = Task.detached(priority: .utility) {
            CodexJSONLScanner.scan(previous: prev.codex)
        }.value

        let claude = await claudeTask
        let codex = await codexTask

        aggregator.ingest(claude.entries)
        aggregator.ingest(codex.entries)
        let conversationChanged = conversationAggregator.ingest(
            entries: claude.entries + codex.entries,
            seeds: claude.conversationSeeds + codex.conversationSeeds
        )

        // 没有真实用量或档案变化时沿用现有代次，只提交轻量 watermark。
        let buckets = aggregator.snapshot()
        let fingerprint = Pricing.fingerprint(knownModels: Set(buckets.map { $0.model }))
        let hasNewEntries = !claude.entries.isEmpty || !codex.entries.isEmpty
        let shouldWriteRollups = loadedRollupGeneration == nil || hasNewEntries || conversationChanged
        let generationID = shouldWriteRollups ? UUID().uuidString : loadedRollupGeneration!
        let newScanState = ScanState(
            generationID: generationID,
            pricingFingerprint: fingerprint,
            claude: claude.newState,
            codex: codex.newState,
            claudeSeenMessageIds: claude.newSeenIds
        )
        let shouldWriteScanState = newScanState != prev

        let rollup: UsageRollupPayload?
        let conversationRollup: ConversationRollupPayload?
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
        } else {
            rollup = nil
            conversationRollup = nil
        }

        let persistenceError: String? = await Task.detached(priority: .utility) {
            do {
                if let rollup, let conversationRollup {
                    // 聚合结果先落盘，watermark 最后提交；generationID 用于启动时识别中断写入。
                    try UsageRollupCache.save(rollup)
                    try ConversationRollupCache.save(conversationRollup)
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
            lastError = persistenceError
            print("[UsageScan 用量扫描] 持久化失败 persistence failed: \(persistenceError)")
            return false
        }

        loadedRollupGeneration = generationID
        lastScanAt = Date()
        lastError = nil
        publishTotals()

        let elapsed = String(format: "%.2fs", Date().timeIntervalSince(started))
        print("[UsageScan 用量扫描] claude files=\(claude.filesScanned) lines=\(claude.linesParsed) new=\(claude.entries.count); codex files=\(codex.filesScanned) lines=\(codex.linesParsed) new=\(codex.entries.count); elapsed=\(elapsed)")
        return true
    }

    private func publishTotals() {
        guard let appState else { return }
        appState.codexTodayCost = aggregator.todayCost(for: .codex)
        appState.claudeTodayCost = aggregator.todayCost(for: .claude)
    }
}
