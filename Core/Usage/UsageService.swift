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
    }

    /// 由 Scheduler / 手动触发；防重入。
    func scanNow() async {
        guard !isScanning else { return }
        let prev = await Task.detached(priority: .utility) {
            ScanCache.load()
        }.value
        await runScan(prev: prev)
    }

    /// 用户在设置页手动触发的强制重算：无视已有 watermark 和 fingerprint，
    /// 清空内存聚合并把本地全部日志按当前 `Pricing.table` 重新解析、重新计费。
    /// 用于「定价表改错后修复，想立刻重算」这类场景，不必等下次价格表变动或重启 App。
    func forceRescan() async {
        guard !isScanning else { return }
        aggregator.load(from: [])
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
        let newScanState = ScanState(
            pricingFingerprint: Pricing.fingerprint,
            claude: claude.newState,
            codex: codex.newState,
            claudeSeenMessageIds: claude.newSeenIds
        )
        let rollup = UsageRollupPayload(
            pricingFingerprint: Pricing.fingerprint,
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
