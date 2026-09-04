import Foundation

/// Scans Claude Code style `projects/**/*.jsonl` roots and turns assistant
/// lines into `UsageEntry`. Incremental by mtime + byte offset; a message.id
/// is counted once across every file (sidechain / subagent files repeat it).
/// Third-party providers driven through Claude Code (Kimi, GLM, Ollama) write
/// the same format, so the caller passes the provider to attribute to.
enum ClaudeJSONLScanner {
    struct Result: Sendable {
        var entries: [UsageEntry]
        var newState: [String: ScanFileState]
        var alivePaths: Set<String>
        var newSeenIds: Set<String>
        var filesScanned: Int
        var linesParsed: Int
    }

    nonisolated static func scan(
        roots: [URL],
        accountId: String,
        provider: Provider,
        previous: [String: ScanFileState],
        seenMessageIds: Set<String>
    ) -> Result {
        var files: [URL] = []
        for root in roots { files.append(contentsOf: JSONLDirectoryEnumerator.files(at: root)) }

        var newState: [String: ScanFileState] = [:]
        var entries: [UsageEntry] = []
        var linesParsed = 0
        var seen = seenMessageIds

        for url in files {
            let path = url.path
            let attrs = try? FileManager.default.attributesOfItem(atPath: path)
            let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let size = (attrs?[.size] as? NSNumber)?.uint64Value ?? 0

            var state = previous[path] ?? ScanFileState(mtime: 0, offset: 0)
            // mtime 没变 & size 没变 → 跳过
            if state.mtime == mtime, state.offset == size {
                newState[path] = state
                continue
            }
            // 文件被截断：offset 回到 0 重扫（此时仍由全局 seen 兜底防重复计费）
            if state.offset > size {
                state.offset = 0
            }

            guard let read = JSONLLineReader.read(url: url, fromOffset: state.offset) else {
                newState[path] = state
                continue
            }

            // 本批次内按 id 收集 candidate，最后挑 stop_reason != nil 的；最终再与全局 seen 比对。
            var candidates: [String: ParsedAssistant] = [:]
            for line in read.lines {
                linesParsed += 1
                guard let parsed = parseAssistantLine(line) else { continue }
                if seen.contains(parsed.messageId) { continue }
                if let existing = candidates[parsed.messageId] {
                    let prefer = (parsed.stopReason != nil && existing.stopReason == nil)
                        || (parsed.outputTokens > existing.outputTokens && existing.stopReason == nil)
                    if prefer { candidates[parsed.messageId] = parsed }
                } else {
                    candidates[parsed.messageId] = parsed
                }
            }

            for (id, p) in candidates {
                seen.insert(id)
                let day = UsageDay.startOfDay(for: p.timestamp)
                let cost = Pricing.cost(
                    model: p.model,
                    input: p.inputTokens,
                    output: p.outputTokens,
                    cacheRead: p.cacheReadTokens,
                    cacheCreation: p.cacheCreationTokens
                )
                entries.append(UsageEntry(
                    accountId: accountId,
                    provider: provider,
                    model: Pricing.normalize(model: p.model),
                    day: day,
                    timestamp: p.timestamp,
                    inputTokens: p.inputTokens,
                    outputTokens: p.outputTokens,
                    cacheReadTokens: p.cacheReadTokens,
                    cacheCreationTokens: p.cacheCreationTokens,
                    costUSD: cost
                ))
            }

            state.mtime = mtime
            state.offset = read.newOffset
            newState[path] = state
        }

        return Result(
            entries: entries,
            newState: newState,
            alivePaths: Set(files.map(\.path)),
            newSeenIds: seen,
            filesScanned: files.count,
            linesParsed: linesParsed
        )
    }

    private struct ParsedAssistant {
        var messageId: String
        var model: String
        var timestamp: Date
        var inputTokens: Int
        var outputTokens: Int
        var cacheReadTokens: Int
        var cacheCreationTokens: Int
        var stopReason: String?
    }

    private nonisolated static func parseTimestamp(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    private nonisolated static func parseAssistantLine(_ line: String) -> ParsedAssistant? {
        guard let data = line.data(using: .utf8) else { return nil }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        guard (root["type"] as? String) == "assistant" else { return nil }
        guard let message = root["message"] as? [String: Any] else { return nil }
        guard let messageId = message["id"] as? String else { return nil }
        guard let usage = message["usage"] as? [String: Any] else { return nil }
        let outputTokens = (usage["output_tokens"] as? Int) ?? 0
        if outputTokens == 0 { return nil }
        let inputTokens = (usage["input_tokens"] as? Int) ?? 0
        let cacheRead = (usage["cache_read_input_tokens"] as? Int) ?? 0
        let cacheCreation = (usage["cache_creation_input_tokens"] as? Int) ?? 0
        let model = (message["model"] as? String) ?? "unknown"
        let stopReason = message["stop_reason"] as? String

        let ts: Date
        if let s = root["timestamp"] as? String, let parsed = parseTimestamp(s) {
            ts = parsed
        } else {
            ts = Date()
        }

        return ParsedAssistant(
            messageId: messageId,
            model: model,
            timestamp: ts,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheReadTokens: cacheRead,
            cacheCreationTokens: cacheCreation,
            stopReason: stopReason
        )
    }
}
