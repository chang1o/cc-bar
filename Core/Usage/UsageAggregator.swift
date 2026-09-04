import Foundation
import Observation

/// In-memory (day, accountId, model) table. `@Observable` so views that read
/// totals in `body` refresh automatically after a scan ingests new entries.
@MainActor
@Observable
final class UsageAggregator {
    private var buckets: [BucketKey: UsageBucket] = [:]

    struct BucketKey: Hashable {
        let day: Date
        let accountId: String
        let model: String
    }

    func load(from snapshot: [UsageBucket]) {
        buckets.removeAll(keepingCapacity: true)
        for b in snapshot {
            buckets[BucketKey(day: b.day, accountId: b.accountId, model: b.model)] = b
        }
    }

    func ingest(_ entries: [UsageEntry]) {
        for e in entries {
            let key = BucketKey(day: e.day, accountId: e.accountId, model: e.model)
            if var b = buckets[key] {
                b.inputTokens += e.inputTokens
                b.outputTokens += e.outputTokens
                b.cacheReadTokens += e.cacheReadTokens
                b.cacheCreationTokens += e.cacheCreationTokens
                b.costUSD += e.costUSD
                buckets[key] = b
            } else {
                buckets[key] = UsageBucket(
                    accountId: e.accountId,
                    provider: e.provider,
                    model: e.model,
                    day: e.day,
                    inputTokens: e.inputTokens,
                    outputTokens: e.outputTokens,
                    cacheReadTokens: e.cacheReadTokens,
                    cacheCreationTokens: e.cacheCreationTokens,
                    costUSD: e.costUSD
                )
            }
        }
    }

    func snapshot() -> [UsageBucket] {
        Array(buckets.values)
    }

    func todayCost(accountId: String, now: Date = Date()) -> Decimal {
        let today = UsageDay.startOfDay(for: now)
        var sum: Decimal = 0
        for b in buckets.values where b.accountId == accountId && b.day == today {
            sum += b.costUSD
        }
        return sum
    }

    func totals(provider: Provider, from: Date, to: Date) -> UsageTotals {
        var totals = UsageTotals.zero
        for b in buckets.values where b.provider == provider && b.day >= from && b.day < to {
            totals.add(b)
        }
        return totals
    }

    func totals(accountId: String, from: Date, to: Date) -> UsageTotals {
        var totals = UsageTotals.zero
        for b in buckets.values where b.accountId == accountId && b.day >= from && b.day < to {
            totals.add(b)
        }
        return totals
    }
}
