import Foundation

/// Per-file scan watermark.
nonisolated struct ScanFileState: Sendable, Equatable, Codable {
    var mtime: Double          // file modification time, epoch seconds
    var offset: UInt64         // bytes already consumed
    /// Codex only: model from the latest `turn_context`, tags later token_count lines.
    var lastModel: String?
}

nonisolated struct ScanState: Sendable, Equatable, Codable {
    /// `version` covers structural changes; price changes are covered by `pricingFingerprint`.
    /// v5: one file map keyed by absolute path across every account root.
    static let currentVersion: Int = 5
    var version: Int = ScanState.currentVersion
    var pricingFingerprint: String = ""
    var files: [String: ScanFileState] = [:]
    /// Claude `message.id` values already counted; the same assistant message
    /// shows up again in sidechain / subagent files.
    var claudeSeenMessageIds: [String] = []
}

enum ScanCache {
    nonisolated private static let fileName = "scan-state.json"
    nonisolated private static let bundleDirectory = "CCBar"

    nonisolated static func load() -> ScanState {
        let url = cacheFileURL()
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(ScanState.self, from: data),
              state.version == ScanState.currentVersion,
              state.pricingFingerprint == Pricing.fingerprint
        else {
            return ScanState()
        }
        return state
    }

    nonisolated static func save(_ state: ScanState) throws {
        let url = cacheFileURL()
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(state)
        try data.write(to: url, options: [.atomic])
    }

    nonisolated static func cacheFileURL() -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Caches", isDirectory: true)
        return caches
            .appendingPathComponent(bundleDirectory, isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
    }
}

/// Aggregated buckets on disk so the UI has numbers right after launch.
nonisolated struct UsageRollupPayload: Sendable, Codable {
    /// v5: buckets carry accountId + provider.
    static let currentVersion: Int = 5
    var version: Int = UsageRollupPayload.currentVersion
    var pricingFingerprint: String = ""
    var buckets: [UsageBucket] = []
    var updatedAt: Date = Date()
}

enum UsageRollupCache {
    nonisolated private static let fileName = "usage-rollup.json"
    nonisolated private static let bundleDirectory = "CCBar"

    nonisolated static func load() -> UsageRollupPayload {
        let url = cacheFileURL()
        guard let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(UsageRollupPayload.self, from: data),
              payload.version == UsageRollupPayload.currentVersion,
              payload.pricingFingerprint == Pricing.fingerprint
        else {
            return UsageRollupPayload()
        }
        return payload
    }

    nonisolated static func save(_ payload: UsageRollupPayload) throws {
        let url = cacheFileURL()
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
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
