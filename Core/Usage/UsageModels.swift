import Foundation

/// One parsed API call from a local JSONL log. Attributed to the monitored
/// account whose usage root the file lives under.
nonisolated struct UsageEntry: Sendable, Equatable {
    var accountId: String
    var provider: Provider
    var model: String
    var day: Date              // local midnight
    var timestamp: Date
    var inputTokens: Int       // cache-read already excluded
    var outputTokens: Int
    var cacheReadTokens: Int
    var cacheCreationTokens: Int
    var costUSD: Decimal
}

/// (day, accountId, model) aggregation bucket persisted in `usage-rollup.json`.
nonisolated struct UsageBucket: Sendable, Equatable, Codable {
    var accountId: String
    var provider: Provider
    var model: String
    var day: Date
    var inputTokens: Int
    var outputTokens: Int
    var cacheReadTokens: Int
    var cacheCreationTokens: Int
    var costUSD: Decimal
}

nonisolated struct UsageTotals: Sendable, Equatable {
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var cacheReadTokens: Int = 0
    var cacheCreationTokens: Int = 0
    var costUSD: Decimal = 0

    static let zero = UsageTotals()

    mutating func add(_ bucket: UsageBucket) {
        inputTokens += bucket.inputTokens
        outputTokens += bucket.outputTokens
        cacheReadTokens += bucket.cacheReadTokens
        cacheCreationTokens += bucket.cacheCreationTokens
        costUSD += bucket.costUSD
    }

    /// input + cache_read + cache_creation, the cc-switch / ccusage convention.
    var inputWithCacheTokens: Int {
        inputTokens + cacheReadTokens + cacheCreationTokens
    }

    var totalTokens: Int {
        inputWithCacheTokens + outputTokens
    }
}

nonisolated extension Decimal {
    var asPlainString: String {
        var copy = self
        return NSDecimalString(&copy, Locale(identifier: "en_US_POSIX"))
    }

    init?(plainString: String) {
        self.init(string: plainString, locale: Locale(identifier: "en_US_POSIX"))
    }
}

nonisolated extension UsageBucket {
    enum CodingKeys: String, CodingKey {
        case accountId, provider, model, day, inputTokens, outputTokens, cacheReadTokens, cacheCreationTokens, costUSD
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.accountId = try c.decode(String.self, forKey: .accountId)
        self.provider = try c.decode(Provider.self, forKey: .provider)
        self.model = try c.decode(String.self, forKey: .model)
        self.day = try c.decode(Date.self, forKey: .day)
        self.inputTokens = try c.decode(Int.self, forKey: .inputTokens)
        self.outputTokens = try c.decode(Int.self, forKey: .outputTokens)
        self.cacheReadTokens = try c.decode(Int.self, forKey: .cacheReadTokens)
        self.cacheCreationTokens = try c.decode(Int.self, forKey: .cacheCreationTokens)
        let costStr = try c.decode(String.self, forKey: .costUSD)
        self.costUSD = Decimal(plainString: costStr) ?? 0
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(accountId, forKey: .accountId)
        try c.encode(provider, forKey: .provider)
        try c.encode(model, forKey: .model)
        try c.encode(day, forKey: .day)
        try c.encode(inputTokens, forKey: .inputTokens)
        try c.encode(outputTokens, forKey: .outputTokens)
        try c.encode(cacheReadTokens, forKey: .cacheReadTokens)
        try c.encode(cacheCreationTokens, forKey: .cacheCreationTokens)
        try c.encode(costUSD.asPlainString, forKey: .costUSD)
    }
}

nonisolated enum UsageDay {
    static func startOfDay(for date: Date) -> Date {
        Calendar.current.startOfDay(for: date)
    }
}
