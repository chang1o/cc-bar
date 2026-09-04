import Foundation

/// 个人历史用量一次性补录（仅本机生效）。
///
/// Claude Code 默认 30 天自动清理会删除 `~/.claude/projects` 下的旧 jsonl，
/// cc-bar 的用量统计依赖重新扫描这些文件，源文件一旦被删就再也算不出对应日期的用量。
/// 这里读取的 JSON 是从本机另一个工具 cc-switch 的历史数据库里一次性导出的缺失日期数据，
/// 详细来源、过滤规则见同目录下的 `imported-usage-claude-2026H1-gapfill.README.md`。
///
/// 文件不存在时整个函数是纯粹的 no-op，不影响其他安装/其他用户。
enum ImportedUsageBackfill {
    nonisolated private static let fileName = "imported-usage-claude-2026H1-gapfill.json"
    nonisolated private static let bundleDirectory = "CCBar"

    nonisolated private static func fileURL() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return support
            .appendingPathComponent(bundleDirectory, isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
    }

    /// 只返回 `existingDays` 里还没有的那些天，避免和实时扫描出来的数据重复计入。
    /// 调用方按当前聚合器里 `app` 已有的日期集合过滤，启动（bootstrap）和每轮扫描（runScan）
    /// 都重新判断，即使以后某天真扫描到了同一天的数据，这里会自动让位、不再重复导入。
    nonisolated static func loadMissingEntries(app: UsageApp, existingDays: Set<Date>) -> [UsageEntry] {
        guard let data = try? Data(contentsOf: fileURL()),
              let buckets = try? JSONDecoder().decode([UsageBucket].self, from: data)
        else {
            return []
        }
        return buckets
            .filter { $0.app == app && !existingDays.contains($0.day) }
            .map { bucket in
                UsageEntry(
                    app: bucket.app,
                    conversationKey: "imported:cc-switch:\(bucket.model)",
                    model: bucket.model,
                    speed: bucket.speed,
                    day: bucket.day,
                    timestamp: bucket.day,
                    inputTokens: bucket.inputTokens,
                    outputTokens: bucket.outputTokens,
                    cacheReadTokens: bucket.cacheReadTokens,
                    cacheCreationTokens: bucket.cacheCreationTokens,
                    requestCount: bucket.requestCount,
                    costUSD: bucket.costUSD,
                    costBreakdown: nil
                )
            }
    }
}
