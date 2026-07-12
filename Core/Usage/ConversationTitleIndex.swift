import Foundation

nonisolated enum ConversationTitleIndex {
    struct ClaudeIndex: Sendable {
        var titles: [String: String]
        var projects: [String: String]
    }

    static func codexTitles() -> [String: String] {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/session_index.jsonl")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var result: [String: String] = [:]
        for line in text.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = root["id"] as? String,
                  let title = clean(root["thread_name"] as? String) else { continue }
            result[id] = title
        }
        return result
    }

    static func claudeIndex() -> ClaudeIndex {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/history.jsonl")
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
        return ClaudeIndex(titles: titles, projects: projects)
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
