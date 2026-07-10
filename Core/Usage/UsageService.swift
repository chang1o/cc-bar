import Foundation

/// 协调 JSONL 扫描 → 聚合 → 持久化 → 通知 AppState 的入口。
@MainActor
final class UsageService {
    let aggregator = UsageAggregator()
    private(set) var isScanning = false
    private(set) var lastScanAt: Date?
    private(set) var lastError: String?

    private weak var appState: AppState?

    func bootstrap(appState: AppState) {
        self.appState = appState
        // 启动同步：先把 rollup 灌进内存
        let payload = UsageRollupCache.load()
        aggregator.load(from: payload.buckets)
        publishTotals()
        // 远端价格目录后台刷新：非阻塞，isDue 内部判断是否真的需要发请求，刷新结果由下次扫描自然拾取。
        PricingCatalogStore.shared.refreshIfNeeded()
    }

    /// 由 Scheduler / 手动触发；防重入。
    func scanNow() async {
        guard !isScanning else { return }
        // 借用量扫描的既有节奏当远端价格目录 24h 到期检查的心跳，不新开定时器；非阻塞。
        PricingCatalogStore.shared.refreshIfNeeded()
        // 本轮扫描的价格表在这里原子切换；之后直到扫描写盘都只读 active 快照。
        PricingCatalogStore.shared.commitPending()
        let knownModels = Set(aggregator.snapshot().map { $0.model })
        let cacheResult = await Task.detached(priority: .utility) {
            ScanCache.load(knownModels: knownModels)
        }.value
        if case .invalidated = cacheResult {
            // 价格/结构失效、缓存损坏或缓存被清理时，下一步会从头扫描；不先清空会把
            // 全量 entries 叠加到旧聚合桶，导致 token 和 cost 静默翻倍。
            aggregator.load(from: [])
            publishTotals()
        }
        await runScan(prev: cacheResult.state)
    }

    /// 用户在设置页手动触发的强制重算：无视已有 watermark 和 fingerprint，
    /// 清空内存聚合并把本地全部日志按当前已提交的价格目录重新解析、重新计费。
    /// 用于「定价表改错后修复，想立刻重算」这类场景，不必等下次价格表变动或重启 App。
    func forceRescan() async {
        guard !isScanning else { return }
        PricingCatalogStore.shared.refreshIfNeeded()
        // 手动重算同样是一次完整扫描：先提交已经刷好的 pending，避免用户刚点击重算
        // 却仍按旧 active 价格扫描；本次刚发起的网络刷新则留给下一次扫描。
        PricingCatalogStore.shared.commitPending()
        aggregator.load(from: [])
        publishTotals()
        await runScan(prev: ScanState())
    }

    private func runScan(prev: ScanState) async {
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false }

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

        // 持久化
        let buckets = aggregator.snapshot()
        let fingerprint = Pricing.fingerprint(knownModels: Set(buckets.map { $0.model }))
        let newScanState = ScanState(
            pricingFingerprint: fingerprint,
            claude: claude.newState,
            codex: codex.newState,
            claudeSeenMessageIds: claude.newSeenIds
        )
        let rollup = UsageRollupPayload(
            pricingFingerprint: fingerprint,
            buckets: buckets,
            updatedAt: Date()
        )
        await Task.detached(priority: .utility) {
            do {
                try ScanCache.save(newScanState)
            } catch {
                print("[UsageScan 用量扫描] 扫描状态写盘失败 scan-state save failed: \(error)")
            }
            do {
                try UsageRollupCache.save(rollup)
            } catch {
                print("[UsageScan 用量扫描] 汇总写盘失败 usage-rollup save failed: \(error)")
            }
        }.value

        lastScanAt = Date()
        lastError = nil
        publishTotals()

        let elapsed = String(format: "%.2fs", Date().timeIntervalSince(started))
        print("[UsageScan 用量扫描] claude files=\(claude.filesScanned) lines=\(claude.linesParsed) new=\(claude.entries.count); codex files=\(codex.filesScanned) lines=\(codex.linesParsed) new=\(codex.entries.count); elapsed=\(elapsed)")
    }

    private func publishTotals() {
        guard let appState else { return }
        appState.codexTodayCost = aggregator.todayCost(for: .codex)
        appState.claudeTodayCost = aggregator.todayCost(for: .claude)
    }
}
