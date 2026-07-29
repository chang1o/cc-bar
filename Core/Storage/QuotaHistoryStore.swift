import Foundation

enum QuotaHistoryAccountKind: String, Sendable, Codable {
    case codexPrimary
    case codexImported
    case codexCCPMProfile
    case claudePrimary
    case claudeCCPMProfile
}

struct QuotaHistorySample: Sendable, Equatable, Codable {
    var accountKey: String
    var app: QuotaApp
    var kind: QuotaHistoryAccountKind
    var sampledAt: Date
    var remainingPercent: Int
    var resetsAt: Date?
}

struct QuotaChangeEvent: Sendable, Equatable, Codable, Identifiable {
    var id: String
    var accountKey: String
    var app: QuotaApp
    var kind: QuotaHistoryAccountKind
    var sampledAt: Date
    var beforeRemainingPercent: Int
    var afterRemainingPercent: Int
    var deltaPercent: Int
    var resetsAt: Date?
}

struct QuotaHistoryPayload: Sendable, Equatable, Codable {
    static let currentVersion = 1

    var version: Int = Self.currentVersion
    var dayStart: Date = QuotaHistoryStore.todayStart()
    var lastSamples: [String: QuotaHistorySample] = [:]
    var events: [QuotaChangeEvent] = []
}

enum QuotaHistoryAccountKey {
    nonisolated static func codexPrimary(accountId: String?) -> String {
        if let id = nonEmpty(accountId) {
            return "codex:primary:\(id)"
        }
        return "codex:primary"
    }

    nonisolated static func codexImported(id: String) -> String {
        "codex:imported:\(id)"
    }

    nonisolated static func codexCCPMProfile(id: String) -> String {
        "codex:ccpm:\(id)"
    }

    nonisolated static func claudePrimary() -> String {
        "claude:primary"
    }

    nonisolated static func claudeCCPMProfile(id: String) -> String {
        "claude:ccpm:\(id)"
    }

    nonisolated private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
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

    nonisolated static func record(
        payload: QuotaHistoryPayload,
        accountKey: String,
        app: QuotaApp,
        kind: QuotaHistoryAccountKind,
        snapshot: QuotaSnapshot,
        sampledAt: Date
    ) -> QuotaHistoryPayload {
        guard let fiveHour = snapshot.fiveHour else {
            return prune(payload, now: sampledAt)
        }

        var next = prune(payload, now: sampledAt)
        let remaining = roundedPercent(fiveHour.remainingPercent)
        let previous = next.lastSamples[accountKey]

        next.lastSamples[accountKey] = QuotaHistorySample(
            accountKey: accountKey,
            app: app,
            kind: kind,
            sampledAt: sampledAt,
            remainingPercent: remaining,
            resetsAt: fiveHour.resetsAt
        )

        guard let previous, previous.remainingPercent != remaining else {
            return next
        }

        let delta = remaining - previous.remainingPercent
        next.events.append(QuotaChangeEvent(
            id: eventId(accountKey: accountKey, sampledAt: sampledAt, before: previous.remainingPercent, after: remaining),
            accountKey: accountKey,
            app: app,
            kind: kind,
            sampledAt: sampledAt,
            beforeRemainingPercent: previous.remainingPercent,
            afterRemainingPercent: remaining,
            deltaPercent: delta,
            resetsAt: fiveHour.resetsAt
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

    nonisolated private static func eventId(
        accountKey: String,
        sampledAt: Date,
        before: Int,
        after: Int
    ) -> String {
        "\(accountKey)|\(Int(sampledAt.timeIntervalSince1970))|\(before)|\(after)"
    }
}
