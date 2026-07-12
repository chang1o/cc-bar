import Foundation
import os

nonisolated enum ConversationTitleIndex {
    struct ClaudeIndex: Sendable {
        var titles: [String: String]
        var projects: [String: String]
    }

    /// 索引文件按 (mtime, size) 缓存解析结果：每轮扫描都会调用，但索引文件
    /// 只在新会话产生时才变化，未变化时跳过整个读盘 + 逐行解析。
    /// Claude / Codex 两个扫描器在并行的 detached task 里各自调用，用锁保护缓存。
    private struct CachedIndex<Value: Sendable>: Sendable {
        var mtime: Date
        var size: UInt64
        var value: Value
    }

    private static let codexCache = OSAllocatedUnfairLock<CachedIndex<[String: String]>?>(initialState: nil)
    private static let claudeCache = OSAllocatedUnfairLock<CachedIndex<ClaudeIndex>?>(initialState: nil)

    static func codexTitles() -> [String: String] {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/session_index.jsonl")
        guard let stamp = fileStamp(at: url) else { return [:] }
        if let cached = codexCache.withLock({ $0 }),
           cached.mtime == stamp.mtime, cached.size == stamp.size {
            return cached.value
        }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var result: [String: String] = [:]
        for line in text.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = root["id"] as? String,
                  let title = clean(root["thread_name"] as? String) else { continue }
            result[id] = title
        }
        codexCache.withLock { $0 = CachedIndex(mtime: stamp.mtime, size: stamp.size, value: result) }
        return result
    }

    static func claudeIndex() -> ClaudeIndex {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/history.jsonl")
        guard let stamp = fileStamp(at: url) else {
            return ClaudeIndex(titles: [:], projects: [:])
        }
        if let cached = claudeCache.withLock({ $0 }),
           cached.mtime == stamp.mtime, cached.size == stamp.size {
            return cached.value
        }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return ClaudeIndex(titles: [:], projects: [:])
        }
        var titles: [String: String] = [:]
        var projects: [String: String] = [:]
        for line in text.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = root["sessionId"] as? String else { continue }
            if titles[id] == nil, let title = clean(root["display"] as? String) {
                titles[id] = title
            }
            if let project = root["project"] as? String, !project.isEmpty {
                projects[id] = project
            }
        }
        let index = ClaudeIndex(titles: titles, projects: projects)
        claudeCache.withLock { $0 = CachedIndex(mtime: stamp.mtime, size: stamp.size, value: index) }
        return index
    }

    private static func fileStamp(at url: URL) -> (mtime: Date, size: UInt64)? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        let mtime = (attrs[.modificationDate] as? Date) ?? .distantPast
        let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        return (mtime, size)
    }

    static func userMessage(from value: Any?) -> String? {
        if let string = value as? String { return clean(string) }
        guard let items = value as? [[String: Any]] else { return nil }
        for item in items where (item["type"] as? String) == "text" {
            if let title = clean(item["text"] as? String) { return title }
        }
        return nil
    }

    static func clean(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let collapsed = raw
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsed.isEmpty, !collapsed.hasPrefix("<") else { return nil }
        return String(collapsed.prefix(80))
    }
}
