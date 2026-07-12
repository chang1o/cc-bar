import Foundation

/// 扫 `~/.codex/sessions/**/*.jsonl` + `~/.codex/archived_sessions/**/*.jsonl`。
/// 关键事件：
///   - `type=turn_context`，`payload.model` 提供当前模型（剥前缀 / 日期后缀）。
///   - `type=event_msg`，`payload.type=token_count`，`payload.info.last_token_usage` 是本次调用的真实 token；
///     使用 last_token_usage 直接累计，不再做累计 delta；info == null 时跳过。
/// Codex `input_tokens` 含 cache_read；GPT-5.6 若日志提供 `cache_write_tokens` 也需从普通输入扣掉。
enum CodexJSONLScanner {
    struct Result: Sendable {
        var entries: [UsageEntry]
        var conversationSeeds: [ConversationSeed]
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
        var filesByID: [String: URL] = [:]
        for root in roots {
            for url in JSONLDirectoryEnumerator.files(at: root) {
                let id = conversationID(from: url) ?? url.path
                if let existing = filesByID[id] {
                    let oldDate = (try? existing.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                    let newDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                    if newDate > oldDate { filesByID[id] = url }
                } else {
                    filesByID[id] = url
                }
            }
        }
        let files = Array(filesByID.values)
        let indexedTitles = ConversationTitleIndex.codexTitles()

        var newState: [String: ScanFileState] = previous
        var entries: [UsageEntry] = []
        var seeds: [String: ConversationSeed] = [:]
        var linesParsed = 0
        var projectResolver = ConversationProjectResolver()
        // 本批次内出现过 cache_write 的对话 key；避免每个文件收尾时对全部
        // 已累积 entries 做线性 contains（全量重扫时是平方级开销）。
        var cacheCreationKeys: Set<String> = []

        for url in files {
            let path = url.path
            let filenameID = conversationID(from: url)
            let stateKey = filenameID ?? path
            let attrs = try? FileManager.default.attributesOfItem(atPath: path)
            let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let size = (attrs?[.size] as? NSNumber)?.uint64Value ?? 0

            var state = previous[stateKey] ?? ScanFileState(mtime: 0, offset: 0)
            if state.mtime == mtime, state.offset == size {
                newState[stateKey] = state
                if let id = state.conversationID ?? filenameID {
                    let key = "codex:\(id)"
                    seeds[key] = ConversationSeed(
                        key: key,
                        id: id,
                        app: .codex,
                        title: indexedTitles[id] ?? state.fallbackTitle,
                        project: projectResolver.resolve(rawPath: state.conversationCwd ?? "", source: .cwd),
                        gitBranch: nil,
                        sourcePath: path,
                        includesSubtasks: false,
                        cacheCreationAvailable: false
                    )
                }
                continue
            }
            if state.offset > size {
                state.offset = 0
                state.lastModel = nil
            }

            guard let read = JSONLLineReader.read(url: url, fromOffset: state.offset) else {
                newState[stateKey] = state
                continue
            }

            var currentModel = state.lastModel
            var sessionID = state.conversationID ?? filenameID
            var sessionCwd = state.conversationCwd ?? ""
            var fallbackTitle = state.fallbackTitle
            for line in read.lines {
                linesParsed += 1
                guard let data = line.data(using: .utf8),
                      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                let type = root["type"] as? String

                if type == "session_meta", let payload = root["payload"] as? [String: Any] {
                    sessionID = (payload["id"] as? String) ?? (payload["session_id"] as? String) ?? sessionID
                    sessionCwd = (payload["cwd"] as? String) ?? sessionCwd
                    continue
                }

                if type == "event_msg",
                   let payload = root["payload"] as? [String: Any],
                   (payload["type"] as? String) == "user_message",
                   fallbackTitle == nil {
                    fallbackTitle = ConversationTitleIndex.clean(payload["message"] as? String)
                    continue
                }

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
                let cacheWrite = cacheWriteTokens(in: last)
                let output = (last["output_tokens"] as? Int) ?? 0
                let billableInput = max(0, inputTotal - cachedInput - cacheWrite)
                if output == 0 && billableInput == 0 && cachedInput == 0 && cacheWrite == 0 { continue }

                let ts: Date
                if let s = root["timestamp"] as? String,
                   let parsed = JSONLTimestamp.parse(s) {
                    ts = parsed
                } else {
                    ts = Date()
                }
                let model = currentModel ?? "unknown"
                guard let resolvedID = sessionID else { continue }
                let cost = Pricing.costBreakdown(
                    model: model,
                    input: billableInput,
                    output: output,
                    cacheRead: cachedInput,
                    cacheCreation: cacheWrite,
                    at: ts,
                    inputTotal: inputTotal
                )
                if cacheWrite > 0 {
                    cacheCreationKeys.insert("codex:\(resolvedID)")
                }
                entries.append(UsageEntry(
                    app: .codex,
                    conversationKey: "codex:\(resolvedID)",
                    model: Pricing.normalize(model: model),
                    day: UsageDay.startOfDay(for: ts),
                    timestamp: ts,
                    inputTokens: billableInput,
                    outputTokens: output,
                    cacheReadTokens: cachedInput,
                    cacheCreationTokens: cacheWrite,
                    costUSD: cost?.total,
                    costBreakdown: cost
                ))
            }

            state.mtime = mtime
            state.offset = read.newOffset
            state.lastModel = currentModel
            state.conversationID = sessionID
            state.conversationCwd = sessionCwd
            state.fallbackTitle = fallbackTitle
            newState[stateKey] = state
            if let id = sessionID {
                let key = "codex:\(id)"
                let hasCacheCreation = cacheCreationKeys.contains(key)
                seeds[key] = ConversationSeed(
                    key: key,
                    id: id,
                    app: .codex,
                    title: indexedTitles[id] ?? fallbackTitle,
                    project: projectResolver.resolve(rawPath: sessionCwd, source: .cwd),
                    gitBranch: nil,
                    sourcePath: path,
                    includesSubtasks: false,
                    cacheCreationAvailable: hasCacheCreation
                )
            }
        }

        let alive = Set(files.map { conversationID(from: $0) ?? $0.path })
        for key in newState.keys where !alive.contains(key) {
            newState.removeValue(forKey: key)
        }

        return Result(entries: entries, conversationSeeds: Array(seeds.values), newState: newState, filesScanned: files.count, linesParsed: linesParsed)
    }

    private nonisolated static func conversationID(from url: URL) -> String? {
        let name = url.deletingPathExtension().lastPathComponent
        let pattern = #"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"#
        guard let range = name.range(of: pattern, options: .regularExpression) else { return nil }
        return String(name[range])
    }

    /// GPT-5.6 的 API usage 可将该字段放在顶层或 input / prompt token details。
    /// 当前 Codex 本地日志未提供时返回 0，不对未记录的缓存写入做推测。
    private nonisolated static func cacheWriteTokens(in usage: [String: Any]) -> Int {
        if let value = usage["cache_write_tokens"] as? Int {
            return value
        }
        for key in ["input_tokens_details", "prompt_tokens_details", "token_details"] {
            if let details = usage[key] as? [String: Any],
               let value = details["cache_write_tokens"] as? Int {
                return value
            }
        }
        return 0
    }
}
