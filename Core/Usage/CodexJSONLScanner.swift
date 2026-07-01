import Foundation

/// 扫 `~/.codex/sessions/**/*.jsonl` + `~/.codex/archived_sessions/**/*.jsonl`。
/// 关键事件：
///   - `type=turn_context`，`payload.model` 提供当前模型（剥前缀 / 日期后缀）。
///   - `type=event_msg`，`payload.type=token_count`，`payload.info.last_token_usage` 是本次调用的真实 token；
///     使用 last_token_usage 直接累计，不再做累计 delta；info == null 时跳过。
/// Codex `input_tokens` 含 cache_read，需在 billable 时扣掉。
enum CodexJSONLScanner {
    struct Result: Sendable {
        var entries: [UsageEntry]
        var newState: [String: ScanFileState]
        var filesScanned: Int
        var linesParsed: Int
    }

    nonisolated static func scan(previous: [String: ScanFileState]) -> Result {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let roots = [
            home.appendingPathComponent(".codex/sessions", isDirectory: true),
            home.appendingPathComponent(".codex/archived_sessions", isDirectory: true)
        ]
        var files: [URL] = []
        for r in roots { files.append(contentsOf: JSONLDirectoryEnumerator.files(at: r)) }

        var newState: [String: ScanFileState] = previous
        var entries: [UsageEntry] = []
        var linesParsed = 0

        for url in files {
            let path = url.path
            let attrs = try? FileManager.default.attributesOfItem(atPath: path)
            let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let size = (attrs?[.size] as? NSNumber)?.uint64Value ?? 0

            var state = previous[path] ?? ScanFileState(mtime: 0, offset: 0)
            if state.mtime == mtime, state.offset == size {
                newState[path] = state
                continue
            }
            if state.offset > size {
                state.offset = 0
                state.lastModel = nil
            }

            guard let read = JSONLLineReader.read(url: url, fromOffset: state.offset) else {
                newState[path] = state
                continue
            }

            var currentModel = state.lastModel
            for line in read.lines {
                linesParsed += 1
                guard let data = line.data(using: .utf8),
                      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                let type = root["type"] as? String

                if type == "turn_context" {
                    if let payload = root["payload"] as? [String: Any],
                       let m = payload["model"] as? String {
                        currentModel = m
                    }
                    continue
                }
                guard type == "event_msg",
                      let payload = root["payload"] as? [String: Any],
                      (payload["type"] as? String) == "token_count" else {
                    continue
                }
                guard let info = payload["info"] as? [String: Any],
                      let last = info["last_token_usage"] as? [String: Any] else {
                    continue
                }
                let inputTotal = (last["input_tokens"] as? Int) ?? 0
                let cachedInput = (last["cached_input_tokens"] as? Int) ?? 0
                let output = (last["output_tokens"] as? Int) ?? 0
                let billableInput = max(0, inputTotal - cachedInput)
                if output == 0 && billableInput == 0 && cachedInput == 0 { continue }

                let ts: Date
                if let s = root["timestamp"] as? String,
                   let parsed = parseISO(s) {
                    ts = parsed
                } else {
                    ts = Date()
                }
                let model = currentModel ?? "unknown"
                let cost = Pricing.cost(
                    model: model,
                    input: billableInput,
                    output: output,
                    cacheRead: cachedInput,
                    cacheCreation: 0,
                    at: ts
                )
                entries.append(UsageEntry(
                    app: .codex,
                    model: Pricing.normalize(model: model),
                    day: UsageDay.startOfDay(for: ts),
                    timestamp: ts,
                    inputTokens: billableInput,
                    outputTokens: output,
                    cacheReadTokens: cachedInput,
                    cacheCreationTokens: 0,
                    costUSD: cost
                ))
            }

            state.mtime = mtime
            state.offset = read.newOffset
            state.lastModel = currentModel
            newState[path] = state
        }

        let alive = Set(files.map { $0.path })
        for key in newState.keys where !alive.contains(key) {
            newState.removeValue(forKey: key)
        }

        return Result(entries: entries, newState: newState, filesScanned: files.count, linesParsed: linesParsed)
    }

    private nonisolated static func parseISO(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}
