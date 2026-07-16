import Foundation

/// 扫 `~/.codex/sessions/**/*.jsonl` + `~/.codex/archived_sessions/**/*.jsonl`。
/// 关键事件：
///   - `type=turn_context`，`payload.model` 提供当前模型（剥前缀 / 日期后缀）。
///   - `type=event_msg/payload.type=thread_settings_applied`，嵌套 `service_tier` 提供当前 Fast 档位。
///   - `type=event_msg`，`payload.type=token_count`，`payload.info.last_token_usage` 是本次调用的真实 token；
///     使用 last_token_usage 直接累计；累计 total_token_usage 未变化的设置回显事件跳过。
/// Codex `input_tokens` 含 cache_read；GPT-5.6 若日志提供 `cache_write_tokens` 也需从普通输入扣掉。
enum CodexJSONLScanner {
    struct ThreadSettings: Sendable, Equatable {
        var model: String?
        var speed: UsageSpeed
    }

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
        return scan(
            previous: previous,
            roots: roots,
            indexedTitles: ConversationTitleIndex.codexTitles()
        )
    }

    /// 可注入日志根目录与标题索引，供脱敏 JSONL fixture 测试真实 byte-offset 扫描链路。
    nonisolated static func scan(
        previous: [String: ScanFileState],
        roots: [URL],
        indexedTitles: [String: String]
    ) -> Result {
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
                resetForTruncation(&state)
            }

            guard let read = JSONLLineReader.read(url: url, fromOffset: state.offset) else {
                newState[stateKey] = state
                continue
            }

            var currentModel = state.lastModel
            var currentSpeed = state.lastServiceTier ?? .standard
            var lastTotalUsageSignature = state.lastCodexTotalUsageSignature
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
                if let settings = threadSettings(from: root) {
                    if let model = settings.model {
                        currentModel = model
                    }
                    currentSpeed = settings.speed
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
                let totalSignature = totalUsageSignature(info["total_token_usage"] as? [String: Any])
                if totalSignature == lastTotalUsageSignature, totalSignature != nil { continue }
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
                if let totalSignature { lastTotalUsageSignature = totalSignature }
                let cost = Pricing.costBreakdown(
                    app: .codex,
                    model: model,
                    speed: currentSpeed,
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
                    speed: currentSpeed,
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
            state.lastServiceTier = currentSpeed
            state.lastCodexTotalUsageSignature = lastTotalUsageSignature
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

    /// 保持为 internal，供脱敏 JSONL fixture 单测验证设置切换与未知值处理。
    nonisolated static func speed(fromServiceTier value: String?) -> UsageSpeed {
        switch value?.lowercased() {
        case "priority", "fast": return .fast
        case "default": return .standard
        default: return .unknown
        }
    }

    /// 解析 Codex 实际 JSONL 的嵌套设置事件；未知档位仍返回设置对象并标成 unknown。
    nonisolated static func threadSettings(from root: [String: Any]) -> ThreadSettings? {
        guard (root["type"] as? String) == "event_msg",
              let payload = root["payload"] as? [String: Any],
              (payload["type"] as? String) == "thread_settings_applied",
              let settings = payload["thread_settings"] as? [String: Any] else {
            return nil
        }
        return ThreadSettings(
            model: settings["model"] as? String,
            speed: speed(fromServiceTier: settings["service_tier"] as? String)
        )
    }

    /// 累计用量的稳定签名。Codex 切换线程设置时可能原样回显上一条 token_count；累计值相同即不是新请求。
    nonisolated static func totalUsageSignature(_ usage: [String: Any]?) -> String? {
        guard let usage else { return nil }
        let keys = [
            "input_tokens",
            "cached_input_tokens",
            "cache_write_tokens",
            "output_tokens",
            "reasoning_output_tokens",
            "total_tokens"
        ]
        let values = keys.map { String((usage[$0] as? Int) ?? 0) }
        guard values.contains(where: { $0 != "0" }) else { return nil }
        return values.joined(separator: ":")
    }

    /// 文件被截断后，offset 与依赖前文的 Codex 解析上下文必须一起重置。
    nonisolated static func resetForTruncation(_ state: inout ScanFileState) {
        state.offset = 0
        state.lastModel = nil
        state.lastServiceTier = nil
        state.lastCodexTotalUsageSignature = nil
    }
}
