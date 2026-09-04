import Foundation

/// Scans every monitored account's JSONL roots, aggregates, persists, and
/// publishes today's cost per account back to `AppState`.
@MainActor
final class UsageService {
    let aggregator = UsageAggregator()
    private(set) var isScanning = false
    private(set) var lastScanAt: Date?
    private(set) var lastError: String?

    private weak var appState: AppState?

    func bootstrap(appState: AppState) {
        self.appState = appState
        let payload = UsageRollupCache.load()
        aggregator.load(from: payload.buckets)
        publishTotals()
    }

    nonisolated private struct ScanTarget: Sendable {
        var accountId: String
        var provider: Provider
        var roots: [URL]
        var isCodex: Bool
    }

    nonisolated private struct ScanOutcome: Sendable {
        var entries: [UsageEntry] = []
        var fileStates: [String: ScanFileState] = [:]
        var alivePaths: Set<String> = []
        var seenIds: Set<String> = []
        var filesScanned = 0
        var linesParsed = 0
    }

    /// Triggered by the scheduler or manual refresh; re-entrancy guarded.
    func scanNow() async {
        guard !isScanning, let appState else { return }
        isScanning = true
        defer { isScanning = false }

        let started = Date()
        let targets = appState.accounts
            .filter { !$0.usageRoots.isEmpty }
            .map { ScanTarget(accountId: $0.id.raw, provider: $0.provider, roots: $0.usageRoots, isCodex: $0.provider == .codex) }

        let prev = await Task.detached(priority: .utility) { ScanCache.load() }.value
        let prevFiles = prev.files
        let prevSeen = Set(prev.claudeSeenMessageIds)

        var merged = ScanOutcome()
        merged.fileStates = prevFiles
        merged.seenIds = prevSeen

        await withTaskGroup(of: ScanOutcome.self) { group in
            var running = 0
            for target in targets {
                if running >= 4, let done = await group.next() { merge(&merged, done); running -= 1 }
                group.addTask(priority: .utility) {
                    Self.scan(target, previous: prevFiles, seen: prevSeen)
                }
                running += 1
            }
            for await done in group { merge(&merged, done) }
        }

        // Drop watermarks for files that vanished from every root.
        merged.fileStates = merged.fileStates.filter { merged.alivePaths.contains($0.key) }

        aggregator.ingest(merged.entries)

        let seenArray = Array(merged.seenIds)
        let cappedSeen = seenArray.count > 20000 ? Array(seenArray.suffix(20000)) : seenArray
        let newScanState = ScanState(
            pricingFingerprint: Pricing.fingerprint,
            files: merged.fileStates,
            claudeSeenMessageIds: cappedSeen
        )
        let rollup = UsageRollupPayload(
            pricingFingerprint: Pricing.fingerprint,
            buckets: aggregator.snapshot(),
            updatedAt: Date()
        )
        await Task.detached(priority: .utility) {
            do { try ScanCache.save(newScanState) } catch {
                print("[UsageScan] scan-state save failed: \(error)")
            }
            do { try UsageRollupCache.save(rollup) } catch {
                print("[UsageScan] usage-rollup save failed: \(error)")
            }
        }.value

        lastScanAt = Date()
        lastError = nil
        publishTotals()

        let elapsed = String(format: "%.2fs", Date().timeIntervalSince(started))
        print("[UsageScan] accounts=\(targets.count) files=\(merged.filesScanned) lines=\(merged.linesParsed) new=\(merged.entries.count) elapsed=\(elapsed)")
    }

    private func merge(_ into: inout ScanOutcome, _ outcome: ScanOutcome) {
        into.entries.append(contentsOf: outcome.entries)
        into.fileStates.merge(outcome.fileStates) { _, new in new }
        into.alivePaths.formUnion(outcome.alivePaths)
        into.seenIds.formUnion(outcome.seenIds)
        into.filesScanned += outcome.filesScanned
        into.linesParsed += outcome.linesParsed
    }

    nonisolated private static func scan(
        _ target: ScanTarget,
        previous: [String: ScanFileState],
        seen: Set<String>
    ) -> ScanOutcome {
        var outcome = ScanOutcome()
        if target.isCodex {
            let result = CodexJSONLScanner.scan(roots: target.roots, accountId: target.accountId, previous: previous)
            outcome.entries = result.entries
            outcome.fileStates = result.newState
            outcome.alivePaths = result.alivePaths
            outcome.filesScanned = result.filesScanned
            outcome.linesParsed = result.linesParsed
        } else {
            let result = ClaudeJSONLScanner.scan(
                roots: target.roots,
                accountId: target.accountId,
                provider: target.provider,
                previous: previous,
                seenMessageIds: seen
            )
            outcome.entries = result.entries
            outcome.fileStates = result.newState
            outcome.alivePaths = result.alivePaths
            outcome.seenIds = result.newSeenIds
            outcome.filesScanned = result.filesScanned
            outcome.linesParsed = result.linesParsed
        }
        return outcome
    }

    private func publishTotals() {
        guard let appState else { return }
        var costs: [AccountID: Decimal] = [:]
        for account in appState.accounts where !account.usageRoots.isEmpty {
            costs[account.id] = aggregator.todayCost(accountId: account.id.raw)
        }
        appState.todayCost = costs
    }
}
