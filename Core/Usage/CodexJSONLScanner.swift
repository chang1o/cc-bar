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
        var failedFileCount: Int
    }

    /// 文件级并发解析的最大并发数。codex 日志文件独立（会话互不重叠），
    /// 全量重扫 / 强制重算是主要耗时场景，多核并行收益明显；受限为 4 避免 IO 争抢过激。
    nonisolated private static let maxConcurrentFiles = 4

    nonisolated static func scan(
        previous: [String: ScanFileState],
        onProgress: ScanProgressCallback? = nil
    ) async -> Result {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let roots = [
            home.appendingPathComponent(".codex/sessions", isDirectory: true),
            home.appendingPathComponent(".codex/archived_sessions", isDirectory: true)
        ]
        return await scan(
            previous: previous,
            roots: roots,
            indexedTitles: ConversationTitleIndex.codexTitles(),
            onProgress: onProgress
        )
    }

    /// 可注入日志根目录与标题索引，供脱敏 JSONL fixture 测试真实 byte-offset 扫描链路。
    /// 文件间并行解析（`maxConcurrentFiles` 路），结果按原始顺序合并，
    /// 解析结果与串行实现完全一致。
    /// - Parameter minimumMtime: 非 nil 时只扫修改时间不早于该时刻的文件（周期受限重建用）。
    /// - Parameter onProgress: 非 nil 时按批回报一次扫描进度。
    nonisolated static func scan(
        previous: [String: ScanFileState],
        roots: [URL],
        indexedTitles: [String: String],
        minimumMtime: Date? = nil,
        onProgress: ScanProgressCallback? = nil
    ) async -> Result {
        var filesByID: [String: JSONLFileDescriptor] = [:]
        var failedRootCount = 0
        for root in roots {
            let enumeration = JSONLDirectoryEnumerator.enumerate(
                at: root,
                minimumMtime: minimumMtime
            )
            if enumeration.accessFailed { failedRootCount += 1 }
            for file in enumeration.files {
                let id = conversationID(from: file.url) ?? file.path
                if let existing = filesByID[id] {
                    if file.modificationTime > existing.modificationTime {
                        filesByID[id] = file
                    }
                } else {
                    filesByID[id] = file
                }
            }
        }
        let files = Array(filesByID.values)

        var newState: [String: ScanFileState] = previous
        var entries: [UsageEntry] = []
        var seeds: [String: ConversationSeed] = [:]
        var linesParsed = 0
        var failedFileCount = failedRootCount
        // 本批次内出现过 cache_write 的会话 key；避免每个文件收尾时对全部
        // 已累积 entries 做线性 contains（全量重扫时是平方级开销）。
        var cacheCreationKeys: Set<String> = []

        // 文件间并行解析：每批 maxConcurrentFiles 个，批内结果合并后再取下一批。
        // 合并按文件原始顺序进行，跨文件共享的 cacheCreationKeys 语义不变——
        // 本批次任意文件写过的会话，最终统一补标到 seed。
        let totalFiles = files.count
        let maxConcurrent = Self.maxConcurrentFiles
        var offset = 0
        while offset < totalFiles {
            let end = min(offset + maxConcurrent, totalFiles)
            var batchResults: [(index: Int, result: CodexFileScanResult)] = []
            await withTaskGroup(of: (Int, CodexFileScanResult).self) { group in
                for index in offset..<end {
                    let file = files[index]
                    let stateKey = conversationID(from: file.url) ?? file.path
                    let state = previous[stateKey]
                    if state?.mtime == file.modificationTime, state?.offset == file.size {
                        batchResults.append((
                            index,
                            scanSingleFile(file: file, previous: previous, indexedTitles: indexedTitles)
                        ))
                    } else {
                        group.addTask {
                            (index, scanSingleFile(
                                file: file,
                                previous: previous,
                                indexedTitles: indexedTitles
                            ))
                        }
                    }
                }
                for await item in group {
                    batchResults.append(item)
                }
            }
            // 按文件原始顺序合并，保证 entries / seeds 顺序与串行实现一致
            batchResults.sort { $0.index < $1.index }
            for item in batchResults {
                let result = item.result
                if result.fileDisappeared {
                    // sessions → archived_sessions 移动时会话 ID 不变；保留旧状态才能让
                    // 下轮从原 offset 续扫，不能删除后把整份归档从 0 重复计入。
                    newState[result.stateKey] = result.state
                    continue
                }
                newState[result.stateKey] = result.state
                entries.append(contentsOf: result.entries)
                linesParsed += result.linesParsed
                if result.readFailed { failedFileCount += 1 }
                for key in result.cacheCreationKeys {
                    cacheCreationKeys.insert(key)
                }
                if let seedKey = result.seedKey, var seed = result.seed {
                    if seed.cacheCreationAvailable {
                        cacheCreationKeys.insert(seedKey)
                    }
                    seeds[seedKey] = seed
                }
            }
            offset = end
            if offset == totalFiles {
                onProgress?(ScanProgress(
                    app: .codex,
                    filesCompleted: totalFiles,
                    filesTotal: totalFiles,
                    linesParsed: linesParsed
                ))
            } else if onProgress != nil {
                onProgress?(ScanProgress(
                    app: .codex,
                    filesCompleted: offset,
                    filesTotal: totalFiles,
                    linesParsed: linesParsed
                ))
            }
        }

        // 批次内任意文件为该会话写过 cache_creation 的，统一补标（与串行全局集合语义一致）
        for key in seeds.keys where cacheCreationKeys.contains(key) {
            if var seed = seeds[key], !seed.cacheCreationAvailable {
                seed.cacheCreationAvailable = true
                seeds[key] = seed
            }
        }

        let alive = Set(files.map { conversationID(from: $0.url) ?? $0.path })
        for key in newState.keys where !alive.contains(key) {
            newState.removeValue(forKey: key)
        }

        return Result(
            entries: entries,
            conversationSeeds: Array(seeds.values),
            newState: newState,
            filesScanned: files.count,
            linesParsed: linesParsed,
            failedFileCount: failedFileCount
        )
    }

    /// 单个文件的解析结果，供并发批处理合并。
    private nonisolated struct CodexFileScanResult: Sendable {
        var stateKey: String
        var state: ScanFileState
        var entries: [UsageEntry]
        var seedKey: String?
        var seed: ConversationSeed?
        var cacheCreationKeys: [String]
        var linesParsed: Int
        var readFailed: Bool
        var fileDisappeared: Bool = false
    }

    /// 解析单个 JSONL 文件（无共享可变状态，可并发执行）。
    /// 原串行实现中每个文件收尾时用"全局 cacheCreationKeys"判断 seed 的
    /// cacheCreationAvailable；并发版把本文件写过的会话 key 放进
    /// `cacheCreationKeys` 返回，由调用方合并后统一补标，语义等价。
    private nonisolated static func scanSingleFile(
        file: JSONLFileDescriptor,
        previous: [String: ScanFileState],
        indexedTitles: [String: String]
    ) -> CodexFileScanResult {
        let url = file.url
        let path = file.path
        let filenameID = conversationID(from: url)
        let stateKey = filenameID ?? path
        let mtime = file.modificationTime
        let size = file.size

        var state = previous[stateKey] ?? ScanFileState(mtime: 0, offset: 0)
        // mtime 没变 & size 没变 → 跳过，用 state 元数据补种子。
        if state.mtime == mtime, state.offset == size {
            if let id = state.conversationID ?? filenameID {
                var projectResolver = ConversationProjectResolver()
                return CodexFileScanResult(
                    stateKey: stateKey,
                    state: state,
                    entries: [],
                    seedKey: "codex:\(id)",
                    seed: ConversationSeed(
                        key: "codex:\(id)",
                        id: id,
                        app: .codex,
                        title: indexedTitles[id] ?? state.fallbackTitle,
                        project: projectResolver.resolve(rawPath: state.conversationCwd ?? "", source: .cwd),
                        gitBranch: nil,
                        sourcePath: path,
                        includesSubtasks: false,
                        cacheCreationAvailable: false
                    ),
                    cacheCreationKeys: [],
                    linesParsed: 0,
                    readFailed: false
                )
            }
            return CodexFileScanResult(
                stateKey: stateKey,
                state: state,
                entries: [],
                seedKey: nil,
                seed: nil,
                cacheCreationKeys: [],
                linesParsed: 0,
                readFailed: false
            )
        }
        // 文件被截断：offset 回到 0 重扫（此时仍由全局 seen 兜底防重复计费）
        if state.offset > size {
            resetForTruncation(&state)
        }

        let read: (lines: [String], newOffset: UInt64)
        switch JSONLLineReader.readOutcome(url: url, fromOffset: state.offset) {
        case let .success(lines, newOffset):
            read = (lines: lines, newOffset: newOffset)
        case .missing:
            return CodexFileScanResult(
                stateKey: stateKey,
                state: state,
                entries: [],
                seedKey: nil,
                seed: nil,
                cacheCreationKeys: [],
                linesParsed: 0,
                readFailed: false,
                fileDisappeared: true
            )
        case .failed:
            return CodexFileScanResult(
                stateKey: stateKey,
                state: state,
                entries: [],
                seedKey: nil,
                seed: nil,
                cacheCreationKeys: [],
                linesParsed: 0,
                readFailed: true
            )
        }

        var linesParsed = 0
        var currentModel = state.lastModel
        var currentSpeed = state.lastServiceTier ?? .standard
        var lastTotalUsageSignature = state.lastCodexTotalUsageSignature
        var sessionID = state.conversationID ?? filenameID
        var sessionCwd = state.conversationCwd ?? ""
        var fallbackTitle = state.fallbackTitle
        var entries: [UsageEntry] = []
        var fileCacheCreationKeys: [String] = []
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
                fileCacheCreationKeys.append("codex:\(resolvedID)")
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

        var seedKey: String?
        var seed: ConversationSeed?
        if let id = sessionID {
            seedKey = "codex:\(id)"
            var projectResolver = ConversationProjectResolver()
            seed = ConversationSeed(
                key: seedKey!,
                id: id,
                app: .codex,
                title: indexedTitles[id] ?? fallbackTitle,
                project: projectResolver.resolve(rawPath: sessionCwd, source: .cwd),
                gitBranch: nil,
                sourcePath: path,
                includesSubtasks: false,
                cacheCreationAvailable: fileCacheCreationKeys.contains(seedKey!)
            )
        }
        return CodexFileScanResult(
            stateKey: stateKey,
            state: state,
            entries: entries,
            seedKey: seedKey,
            seed: seed,
            cacheCreationKeys: fileCacheCreationKeys,
            linesParsed: linesParsed,
            readFailed: false
        )
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
