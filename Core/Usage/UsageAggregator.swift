import Foundation
import Observation

/// 按 (day, app, model, speed) 聚合的内存表。
///
/// 标记为 `@Observable`：`snapshot()` / `todayCost(...)` / `totals(...)` 在 SwiftUI
/// body 内访问 `buckets` 时会自动登记依赖，扫描完成后 `ingest` 写回 `buckets`
/// 触发的变更会驱动所有读这个聚合器的视图自动刷新。视图侧无需任何额外订阅。
@MainActor
@Observable
final class UsageAggregator {
    private var buckets: [BucketKey: UsageBucket] = [:]

    struct BucketKey: Hashable {
        let day: Date
        let app: UsageApp
        let model: String
        let speed: UsageSpeed
    }

    func load(from snapshot: [UsageBucket]) {
        buckets.removeAll(keepingCapacity: true)
        for b in snapshot {
            let key = BucketKey(day: b.day, app: b.app, model: b.model, speed: b.speed)
            buckets[key] = b
        }
    }

    func ingest(_ entries: [UsageEntry]) {
        for e in entries {
            let key = BucketKey(day: e.day, app: e.app, model: e.model, speed: e.speed)
            if var b = buckets[key] {
                b.inputTokens += e.inputTokens
                b.outputTokens += e.outputTokens
                b.cacheReadTokens += e.cacheReadTokens
                b.cacheCreationTokens += e.cacheCreationTokens
                // 缺少可靠价格（nil）按 0 计入聚合；桶内标记仅保留给诊断，不影响 UI 数值展示。
                b.costUSD += e.costUSD ?? 0
                b.requestCount += e.requestCount
                b.hasUnpricedUsage = b.hasUnpricedUsage || e.costUSD == nil
                buckets[key] = b
            } else {
                buckets[key] = UsageBucket(
                    app: e.app,
                    model: e.model,
                    speed: e.speed,
                    day: e.day,
                    inputTokens: e.inputTokens,
                    outputTokens: e.outputTokens,
                    cacheReadTokens: e.cacheReadTokens,
                    cacheCreationTokens: e.cacheCreationTokens,
                    costUSD: e.costUSD ?? 0,
                    requestCount: e.requestCount,
                    hasUnpricedUsage: e.costUSD == nil
                )
            }
        }
    }

    func snapshot() -> [UsageBucket] {
        Array(buckets.values)
    }

    func todayCost(for app: UsageApp, now: Date = Date()) -> Decimal {
        let today = UsageDay.startOfDay(for: now)
        var sum: Decimal = 0
        for b in buckets.values where b.app == app && b.day == today {
            sum += b.costUSD
        }
        return sum
    }

    /// 给 M6 复用：按时间范围 / 应用聚合。
    func totals(app: UsageApp, from: Date, to: Date) -> UsageTotals {
        var totals = UsageTotals.zero
        for b in buckets.values where b.app == app && b.day >= from && b.day < to {
            totals.add(b)
        }
        return totals
    }
}
