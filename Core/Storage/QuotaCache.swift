import Foundation

nonisolated struct QuotaCacheRecord: Sendable, Equatable, Codable {
    var snapshot: QuotaSnapshot
    var source: QuotaSnapshotSource
    var updatedAt: Date
}

/// v2: one record per monitored account, keyed by `AccountID.raw`.
/// Older payloads are discarded; the next refresh repopulates them.
nonisolated struct QuotaCachePayload: Sendable, Equatable, Codable {
    static let currentVersion = 2
    var version: Int = QuotaCachePayload.currentVersion
    var records: [String: QuotaCacheRecord] = [:]
}

enum QuotaCache {
    nonisolated private static let fileName = "quota-cache.json"
    nonisolated private static let bundleDirectory = "CCBar"

    nonisolated static func load() -> QuotaCachePayload {
        let url = cacheFileURL()
        guard let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(QuotaCachePayload.self, from: data),
              payload.version == QuotaCachePayload.currentVersion
        else {
            return QuotaCachePayload()
        }
        return payload
    }

    nonisolated static func save(_ payload: QuotaCachePayload) throws {
        let url = cacheFileURL()
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(payload)
        try data.write(to: url, options: [.atomic])
    }

    nonisolated static func cacheFileURL() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return support
            .appendingPathComponent(bundleDirectory, isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
    }
}
