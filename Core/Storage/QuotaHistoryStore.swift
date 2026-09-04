import Foundation

nonisolated struct QuotaHistorySample: Sendable, Equatable, Codable {
    var accountKey: String
    var provider: Provider
    var sampledAt: Date
    var remainingPercent: Int
    var resetsAt: Date?
}

nonisolated struct QuotaChangeEvent: Sendable, Equatable, Codable, Identifiable {
    var id: String
    var accountKey: String
    var provider: Provider
    var sampledAt: Date
    var beforeRemainingPercent: Int
    var afterRemainingPercent: Int
    var deltaPercent: Int
    var resetsAt: Date?
}

/// v2: keyed by `AccountID.raw`, no per-source account kinds.
nonisolated struct QuotaHistoryPayload: Sendable, Equatable, Codable {
    static let currentVersion = 2

    var version: Int = Self.currentVersion
    var dayStart: Date = QuotaHistoryStore.todayStart()
    var lastSamples: [String: QuotaHistorySample] = [:]
    var events: [QuotaChangeEvent] = []
}

enum QuotaHistoryStore {
    nonisolated private static let fileName = "quota-history-today.json"
    nonisolated private static let bundleDirectory = "CCBar"

    nonisolated static func load(now: Date = Date()) -> QuotaHistoryPayload {
        let url = fileURL()
        guard let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(QuotaHistoryPayload.self, from: data),
              payload.version == QuotaHistoryPayload.currentVersion
        else {
            return QuotaHistoryPayload(dayStart: todayStart(now: now))
        }
        return prune(payload, now: now)
    }

    nonisolated static func save(_ payload: QuotaHistoryPayload) throws {
        let url = fileURL()
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(payload)
        try data.write(to: url, options: [.atomic])
    }

    /// Records the tracked window (five-hour lane, else primary) and appends a
    /// change event only when the rounded remaining percent moved.
    nonisolated static func record(
        payload: QuotaHistoryPayload,
        accountKey: String,
        provider: Provider,
        snapshot: QuotaSnapshot,
        sampledAt: Date
    ) -> QuotaHistoryPayload {
        guard let window = snapshot.timelineWindow else {
            return prune(payload, now: sampledAt)
        }

        var next = prune(payload, now: sampledAt)
        let remaining = roundedPercent(window.remainingPercent)
        let previous = next.lastSamples[accountKey]

        next.lastSamples[accountKey] = QuotaHistorySample(
            accountKey: accountKey,
            provider: provider,
            sampledAt: sampledAt,
            remainingPercent: remaining,
            resetsAt: window.resetsAt
        )

        guard let previous, previous.remainingPercent != remaining else {
            return next
        }

        let delta = remaining - previous.remainingPercent
        next.events.append(QuotaChangeEvent(
            id: "\(accountKey)|\(Int(sampledAt.timeIntervalSince1970))|\(previous.remainingPercent)|\(remaining)",
            accountKey: accountKey,
            provider: provider,
            sampledAt: sampledAt,
            beforeRemainingPercent: previous.remainingPercent,
            afterRemainingPercent: remaining,
            deltaPercent: delta,
            resetsAt: window.resetsAt
        ))
        return next
    }

    nonisolated static func todayStart(now: Date = Date()) -> Date {
        Calendar.current.startOfDay(for: now)
    }

    nonisolated static func fileURL() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return support
            .appendingPathComponent(bundleDirectory, isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
    }

    nonisolated private static func prune(_ payload: QuotaHistoryPayload, now: Date) -> QuotaHistoryPayload {
        let start = todayStart(now: now)
        guard Calendar.current.isDate(payload.dayStart, inSameDayAs: start) else {
            return QuotaHistoryPayload(dayStart: start)
        }

        var next = payload
        next.dayStart = start
        next.events = next.events.filter { Calendar.current.isDate($0.sampledAt, inSameDayAs: start) }
        next.lastSamples = next.lastSamples.filter { Calendar.current.isDate($0.value.sampledAt, inSameDayAs: start) }
        return next
    }

    nonisolated private static func roundedPercent(_ value: Double) -> Int {
        max(0, min(100, Int(value.rounded())))
    }
}
