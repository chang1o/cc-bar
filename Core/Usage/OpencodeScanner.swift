import Foundation
import SQLite3

/// 扫 OpenCode 的 SQLite 会话库（`~/.local/share/opencode/opencode.db`，Desktop / CLI 共用）。
///
/// OpenCode 不是订阅服务、没有额度，但其会话库自带官方聚合好的 token 与 cost；
/// 定位与 Pi 一致：只进主窗口本地用量统计，不进额度轮询 / 菜单栏 / Popover / 悬浮窗 / Timeline。
///
/// 解析规则：
///   - `message` 表每行一条消息，`data` JSON：user 消息带嵌套 `model{providerID, modelID, variant}`，
///     assistant 消息自身带顶层 `providerID` / `modelID`；模型标签优先读消息自身字段，
///     读不到时回退到会话内最近 user 消息继承的模型（避免增量扫描时标签丢失）。
///   - assistant 消息带 `cost`（USD）与 `tokens{input, output, reasoning, cache{read, write}}`。
///   - reasoning 并入 output（与 Claude / Codex 的 output 含 thinking 口径一致）。
///   - 模型标签格式 `providerID/modelID`（对齐 Pi 的 `provider/model`），variant 不拼入，
///     价格差异由官方 cost 兜底。
///   - 费用：总额优先官方 `cost`；分项用本地 / 远端价格目录补算（Pricing.costBreakdown），
///     查不到价格时官方总额降级计入 output，保证对话页总额与统计页一致且不误标「未定价」。
///   - `session` 表提供 title / directory，`workspace` 表提供 branch；空标题用该会话
///     首条 text part 兜底。
///
/// 增量逻辑：watermark 为 `max(message.time_created)`（Unix 毫秒），查询 `>= watermark`
/// 并按 message.id 全局去重兜底 compaction / 时间戳回跳；被删除的会话不回扫（与 JSONL
/// append-only 假设一致）。只读打开（SQLITE_OPEN_READONLY），与 OpenCode 运行中的写入
/// 通过 WAL 并发安全；库缺失 / 打开失败 / 表结构不符时 no-op 返回原状态。
enum OpencodeScanner {
    struct Result: Sendable {
        var entries: [UsageEntry]
        var conversationSeeds: [ConversationSeed]
        var newLastMessageTime: Int64
        var newSeenMessageIds: [String]
        var messagesRead: Int
    }

    nonisolated static func defaultDatabaseURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/opencode/opencode.db", isDirectory: false)
    }

    nonisolated static func scan(
        lastMessageTime: Int64,
        seenMessageIds: [String],
        onProgress: ScanProgressCallback? = nil
    ) -> Result {
        scan(
            lastMessageTime: lastMessageTime,
            seenMessageIds: seenMessageIds,
            databaseURL: defaultDatabaseURL(),
            onProgress: onProgress
        )
    }

    /// 可注入库路径，供测试用临时 SQLite fixture 验证真实增量链路。
    /// - Parameter onProgress: 非 nil 时按约每 200 条消息回报一次扫描进度。
    ///   SQLite 库无法预知总行数，`filesTotal` 固定为 0 表示未知。
    nonisolated static func scan(
        lastMessageTime: Int64,
        seenMessageIds: [String],
        databaseURL: URL,
        onProgress: ScanProgressCallback? = nil
    ) -> Result {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            return Result(
                entries: [],
                conversationSeeds: [],
                newLastMessageTime: lastMessageTime,
                newSeenMessageIds: seenMessageIds,
                messagesRead: 0
            )
        }

        var db: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            return Result(
                entries: [],
                conversationSeeds: [],
                newLastMessageTime: lastMessageTime,
                newSeenMessageIds: seenMessageIds,
                messagesRead: 0
            )
        }
        defer { sqlite3_close(db) }

        let messageSQL = """
        SELECT m.id, m.session_id, m.time_created, m.data, s.title, s.directory, w.branch
        FROM message m
        JOIN session s ON s.id = m.session_id
        LEFT JOIN workspace w ON w.id = s.workspace_id
        WHERE m.time_created >= ?1
        ORDER BY m.time_created, m.id
        """
        guard let stmt = prepare(db, sql: messageSQL, bind: { sqlite3_bind_int64($0, 1, lastMessageTime) }) else {
            // 表结构不符（OpenCode 未来版本可能迁移）：本轮 no-op，保留原 watermark。
            return Result(
                entries: [],
                conversationSeeds: [],
                newLastMessageTime: lastMessageTime,
                newSeenMessageIds: seenMessageIds,
                messagesRead: 0
            )
        }

        var entries: [UsageEntry] = []
        var seen = Set(seenMessageIds)
        var lastTime = lastMessageTime
        var messagesRead = 0
        var lastModelBySession: [String: String] = [:]
        var sessionsWithEntries: Set<String> = []
        var sessionMeta: [String: SessionMeta] = [:]

        while sqlite3_step(stmt) == SQLITE_ROW {
            messagesRead += 1
            if messagesRead % 200 == 0 {
                onProgress?(ScanProgress(
                    app: .opencode,
                    filesCompleted: messagesRead,
                    filesTotal: 0,
                    linesParsed: messagesRead
                ))
            }
            guard let messageID = columnText(stmt, 0),
                  let sessionID = columnText(stmt, 1) else { continue }
            let timeCreated = sqlite3_column_int64(stmt, 2)
            guard let data = columnText(stmt, 3),
                  let json = try? JSONSerialization.jsonObject(
                    with: Data(data.utf8)
                  ) as? [String: Any] else { continue }
            let title = columnText(stmt, 4)
            let directory = columnText(stmt, 5) ?? ""
            let branch = columnText(stmt, 6)

            lastTime = max(lastTime, timeCreated)
            let role = json["role"] as? String
            if role == "user" {
                // user 消息带嵌套 `model` 对象，继承给后续 assistant 兜底。
                if let model = parseModel(json["model"]) {
                    lastModelBySession[sessionID] = model
                }
                continue
            }
            guard role == "assistant" else { continue }
            if seen.contains(messageID) { continue }
            seen.insert(messageID)

            guard let tokens = json["tokens"] as? [String: Any] else { continue }
            let cost = decimalValue(json["cost"])
            let input = intValue(tokens["input"])
            let output = intValue(tokens["output"]) + intValue(tokens["reasoning"])
            let cache = tokens["cache"] as? [String: Any] ?? [:]
            let cacheRead = intValue(cache["read"])
            let cacheWrite = intValue(cache["write"])
            // total 为 0 且无 cost（或官方 cost 为 0）的消息（工具调用收尾等）不产生用量。
            if intValue(tokens["total"]) <= 0 && (cost == nil || cost == 0) { continue }

            // assistant 消息自身带顶层 providerID/modelID，优先于会话继承的 user 模型；
            // 增量扫描只追加 assistant 时继承为空，靠自身字段保证标签不丢。
            let model = parseModel(json) ?? lastModelBySession[sessionID] ?? "unknown/unknown"
            let timestamp = Date(timeIntervalSince1970: Double(timeCreated) / 1000)
            entries.append(makeEntry(
                conversationID: sessionID,
                model: model,
                timestamp: timestamp,
                input: input,
                output: output,
                cacheRead: cacheRead,
                cacheWrite: cacheWrite,
                cost: cost
            ))
            sessionsWithEntries.insert(sessionID)
            if sessionMeta[sessionID] == nil {
                sessionMeta[sessionID] = SessionMeta(title: title, directory: directory, branch: branch)
            }
        }
        sqlite3_finalize(stmt)

        let fallbackTitles = fallbackTitles(db, for: Set(sessionMeta.filter {
            $0.value.title == nil || $0.value.title!.isEmpty
        }.keys))

        var seeds: [String: ConversationSeed] = [:]
        var projectResolver = ConversationProjectResolver()
        for sessionID in sessionsWithEntries {
            guard let meta = sessionMeta[sessionID] else { continue }
            let resolvedTitle = nonEmpty(meta.title) ?? fallbackTitles[sessionID]
            seeds["opencode:\(sessionID)"] = ConversationSeed(
                key: "opencode:\(sessionID)",
                id: sessionID,
                app: .opencode,
                title: resolvedTitle,
                project: projectResolver.resolve(rawPath: meta.directory, source: .cwd),
                gitBranch: nonEmpty(meta.branch),
                sourcePath: databaseURL.path,
                includesSubtasks: false,
                cacheCreationAvailable: true
            )
        }

        // 控制全局 seen 集合大小：保留最近 20000 条（与 Claude / Pi scanner 一致）。
        let seenArr = Array(seen)
        let cappedSeen = seenArr.count > 20000 ? Array(seenArr.suffix(20000)) : seenArr

        return Result(
            entries: entries,
            conversationSeeds: Array(seeds.values),
            newLastMessageTime: lastTime,
            newSeenMessageIds: cappedSeen,
            messagesRead: messagesRead
        )
    }

    /// 会话静态信息快照（来自 session / workspace 表）。
    private nonisolated struct SessionMeta {
        var title: String?
        var directory: String
        var branch: String?
    }

    /// SQLITE_TRANSIENT 是 C 宏，Swift 中须经 unsafeBitCast 表达「SQLite 自行拷贝文本」。
    private nonisolated static let sqliteTransient: sqlite3_destructor_type =
        unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// 空标题会话的首条 text part 作为标题兜底；查询只对少量会话执行。
    private nonisolated static func fallbackTitles(
        _ db: OpaquePointer,
        for sessionIDs: Set<String>
    ) -> [String: String] {
        guard !sessionIDs.isEmpty else { return [:] }
        var result: [String: String] = [:]
        let sql = "SELECT data FROM part WHERE session_id = ?1 ORDER BY time_created, id LIMIT 1"
        for sessionID in sessionIDs {
            guard let stmt = prepare(db, sql: sql, bind: { sqlite3_bind_text($0, 1, sessionID, -1, sqliteTransient) }) else {
                continue
            }
            if sqlite3_step(stmt) == SQLITE_ROW,
               let data = columnText(stmt, 0),
               let json = try? JSONSerialization.jsonObject(
                 with: Data(data.utf8)
               ) as? [String: Any],
               (json["type"] as? String) == "text",
               let title = ConversationTitleIndex.clean(json["text"] as? String) {
                result[sessionID] = title
            }
            sqlite3_finalize(stmt)
        }
        return result
    }

    private nonisolated static func prepare(
        _ db: OpaquePointer,
        sql: String,
        bind: (OpaquePointer) -> Void
    ) -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return nil }
        bind(stmt)
        return stmt
    }

    private nonisolated static func columnText(_ stmt: OpaquePointer, _ index: Int32) -> String? {
        guard let c = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: c)
    }

    private nonisolated static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 模型标签解析：user 消息用嵌套 `model{providerID, modelID, variant}`，
    /// assistant 消息用顶层 `providerID` / `modelID`；两种结构均可直接解析。
    /// 标签格式 `providerID/modelID`；variant 不拼入。
    private nonisolated static func parseModel(_ value: Any?) -> String? {
        let dict = value as? [String: Any]
        guard let providerID = dict?["providerID"] as? String, !providerID.isEmpty,
              let modelID = dict?["modelID"] as? String, !modelID.isEmpty else { return nil }
        return "\(providerID)/\(modelID)"
    }

    private nonisolated static func makeEntry(
        conversationID: String,
        model: String,
        timestamp: Date,
        input: Int,
        output: Int,
        cacheRead: Int,
        cacheWrite: Int,
        cost: Decimal?
    ) -> UsageEntry {
        let breakdown: CostBreakdown?
        if let cost {
            if let priced = Pricing.costBreakdown(
                app: .opencode,
                model: model,
                speed: .standard,
                input: input,
                output: output,
                cacheRead: cacheRead,
                cacheCreation: cacheWrite,
                at: timestamp
            ) {
                breakdown = priced
            } else {
                // 官方 cost 可靠但本地 / 远端价格目录未收录该模型：总额降级计入 output，
                // 保证对话页与统计页总额一致，且不误标「未定价」。
                breakdown = CostBreakdown(input: 0, output: cost, cacheRead: 0, cacheCreation: 0)
            }
        } else {
            breakdown = nil
        }
        return UsageEntry(
            app: .opencode,
            conversationKey: "opencode:\(conversationID)",
            model: model,
            speed: .standard,
            day: UsageDay.startOfDay(for: timestamp),
            timestamp: timestamp,
            inputTokens: input,
            outputTokens: output,
            cacheReadTokens: cacheRead,
            cacheCreationTokens: cacheWrite,
            requestCount: 1,
            costUSD: cost,
            costBreakdown: breakdown
        )
    }

    private nonisolated static func intValue(_ value: Any?) -> Int {
        if let n = value as? NSNumber { return n.intValue }
        if let s = value as? String { return Int(s) ?? 0 }
        return 0
    }

    /// 经 String 中转避免 Double → Decimal 的二进制浮点误差。
    private nonisolated static func decimalValue(_ value: Any?) -> Decimal? {
        if let n = value as? NSNumber {
            return Decimal(string: n.stringValue)
        }
        if let s = value as? String {
            return Decimal(string: s)
        }
        return nil
    }
}
