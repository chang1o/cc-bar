import Foundation

/// Cursor Dashboard 已完整拉取的本地自然日范围，`endDay` 为开区间。
nonisolated struct CursorUsageDayRange: Sendable, Equatable, Codable {
    var startDay: Date
    var endDay: Date

    init?(range: Range<Date>) {
        guard range.lowerBound < range.upperBound else { return nil }
        startDay = range.lowerBound
        endDay = range.upperBound
    }

    var range: Range<Date> { startDay..<endDay }
}

/// Cursor 远端日桶与覆盖范围。独立于本地 `usage-rollup.json`：后者受本地扫描
/// generation / Pricing fingerprint 管理，绝不能被远端数据变化牵连失效。
nonisolated struct CursorUsageCachePayload: Sendable, Equatable, Codable {
    static let currentVersion = 1

    var version: Int = Self.currentVersion
    /// JWT userID，不保存 Cookie 或 access token。
    var accountID: String? = nil
    var buckets: [UsageBucket] = []
    var coveredDayRanges: [CursorUsageDayRange] = []
    var updatedAt: Date?
}

nonisolated enum CursorUsageCache {
    private static let fileName = "cursor-usage-rollup.json"
    private static let bundleDirectory = "CCBar"

    static func load() -> CursorUsageCachePayload {
        let url = fileURL()
        guard let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(CursorUsageCachePayload.self, from: data),
              payload.version == CursorUsageCachePayload.currentVersion
        else {
            return CursorUsageCachePayload()
        }
        return payload
    }

    static func save(_ payload: CursorUsageCachePayload) throws {
        let url = fileURL()
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(payload)
        try data.write(to: url, options: [.atomic])
    }

    static func fileURL() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return support
            .appendingPathComponent(bundleDirectory, isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
    }
}

extension Array where Element == CursorUsageDayRange {
    /// 插入后规范化为按日期排序、互相不重叠且相邻即合并的覆盖区间。
    nonisolated func merged(with next: CursorUsageDayRange) -> [CursorUsageDayRange] {
        let sorted = (self + [next]).sorted { $0.startDay < $1.startDay }
        var result: [CursorUsageDayRange] = []
        for item in sorted {
            guard var previous = result.last else {
                result.append(item)
                continue
            }
            if item.startDay <= previous.endDay {
                previous.endDay = Swift.max(previous.endDay, item.endDay)
                result[result.count - 1] = previous
            } else {
                result.append(item)
            }
        }
        return result
    }

    /// 返回目标自然日区间中尚未被完整覆盖的片段。调用方可据此按月补拉，
    /// 所有片段完成后再整体发布，补拉过程不生成额外页面状态。
    nonisolated func missingRanges(in target: Range<Date>) -> [Range<Date>] {
        guard target.lowerBound < target.upperBound else { return [] }

        let covered = sorted { $0.startDay < $1.startDay }
        var cursor = target.lowerBound
        var missing: [Range<Date>] = []

        for item in covered {
            guard item.endDay > cursor else { continue }
            if item.startDay > cursor {
                let end = Swift.min(item.startDay, target.upperBound)
                if cursor < end {
                    missing.append(cursor..<end)
                }
            }
            cursor = Swift.max(cursor, item.endDay)
            if cursor >= target.upperBound { break }
        }

        if cursor < target.upperBound {
            missing.append(cursor..<target.upperBound)
        }
        return missing
    }
}
