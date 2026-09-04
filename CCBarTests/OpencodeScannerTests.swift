import XCTest
import SQLite3
@testable import CCBar

/// OpencodeScanner 的 SQLite fixture 测试：全量解析、增量 watermark、seen 去重、
/// reasoning 并入 output、日志价格优先与统一 Pricing 补算、空标题 part 兜底、项目与 branch。
final class OpencodeScannerTests: XCTestCase {
    private var tempDir: URL!
    private var dbURL: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("opencode-scan-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        dbURL = tempDir.appendingPathComponent("opencode.db")
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    // MARK: - Fixture helpers

    /// 创建与 OpenCode 一致的 session / message / part / workspace / project 表结构。
    @discardableResult
    private func createSchema() throws -> OpaquePointer {
        var opened: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(dbURL.path, &opened, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil), SQLITE_OK)
        let db = opened!
        let statements = [
            "CREATE TABLE IF NOT EXISTS project (id TEXT PRIMARY KEY, worktree TEXT NOT NULL, vcs TEXT, name TEXT, time_created INTEGER NOT NULL)",
            "CREATE TABLE IF NOT EXISTS workspace (id TEXT PRIMARY KEY, type TEXT NOT NULL, name TEXT DEFAULT '' NOT NULL, branch TEXT, directory TEXT, extra TEXT, project_id TEXT NOT NULL, time_used INTEGER NOT NULL)",
            "CREATE TABLE IF NOT EXISTS session (id TEXT PRIMARY KEY, project_id TEXT NOT NULL, workspace_id TEXT, title TEXT NOT NULL, cost REAL DEFAULT 0 NOT NULL, time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL, directory TEXT NOT NULL)",
            "CREATE TABLE IF NOT EXISTS message (id TEXT PRIMARY KEY, session_id TEXT NOT NULL, time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL, data TEXT NOT NULL)",
            "CREATE TABLE IF NOT EXISTS part (id TEXT PRIMARY KEY, message_id TEXT NOT NULL, session_id TEXT NOT NULL, time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL, data TEXT NOT NULL)",
        ]
        for sql in statements {
            var stmt: OpaquePointer?
            XCTAssertEqual(sqlite3_prepare_v2(db, sql, -1, &stmt, nil), SQLITE_OK)
            XCTAssertEqual(sqlite3_step(stmt), SQLITE_DONE)
            sqlite3_finalize(stmt)
        }
        return db
    }

    private func exec(_ db: OpaquePointer, _ sql: String, _ args: [Any]) {
        var prepared: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, sql, -1, &prepared, nil), SQLITE_OK)
        let stmt = prepared!
        for (i, arg) in args.enumerated() {
            let idx = Int32(i + 1)
            switch arg {
            case let s as String:
                sqlite3_bind_text(stmt, idx, s, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            case let i as Int: sqlite3_bind_int64(stmt, idx, Int64(i))
            case let d as Double: sqlite3_bind_double(stmt, idx, d)
            default: XCTFail("unsupported fixture arg \(arg)")
            }
        }
        XCTAssertEqual(sqlite3_step(stmt), SQLITE_DONE)
        sqlite3_finalize(stmt)
    }

    private func insertSession(
        _ db: OpaquePointer,
        id: String,
        title: String,
        directory: String,
        workspace: String? = "ws-1",
        timeCreated: Int = 1_786_075_934_005
    ) {
        exec(db, "INSERT INTO session (id, project_id, workspace_id, title, time_created, time_updated, directory) VALUES (?, 'p1', ?, ?, ?, ?, ?)",
             [id, workspace ?? "", title, timeCreated, timeCreated, directory])
    }

    private func insertMessage(
        _ db: OpaquePointer,
        id: String,
        sessionID: String,
        timeCreated: Int,
        data: String
    ) {
        exec(db, "INSERT INTO message (id, session_id, time_created, time_updated, data) VALUES (?, ?, ?, ?, ?)",
             [id, sessionID, timeCreated, timeCreated, data])
    }

    private func insertPart(
        _ db: OpaquePointer,
        id: String,
        messageID: String,
        sessionID: String,
        timeCreated: Int,
        data: String
    ) {
        exec(db, "INSERT INTO part (id, message_id, session_id, time_created, time_updated, data) VALUES (?, ?, ?, ?, ?, ?)",
             [id, messageID, sessionID, timeCreated, timeCreated, data])
    }

    private func userMessageData(modelID: String = "deepseek-v4-flash", providerID: String = "opencode-go") -> String {
        #"{"role":"user","time":{"created":1786075934005},"agent":"build","model":{"providerID":"\#(providerID)","modelID":"\#(modelID)","variant":"max"},"summary":{"diffs":[]}}"#
    }

    private func assistantMessageData(
        cost: Double? = 0.00148148,
        input: Int = 10_546,
        output: Int = 18,
        reasoning: Int = 0,
        cacheRead: Int = 0,
        cacheWrite: Int = 0,
        providerID: String? = "opencode-go",
        modelID: String? = "deepseek-v4-flash"
    ) -> String {
        let total = input + output + reasoning + cacheRead + cacheWrite
        let modelPart: String
        if let providerID, let modelID {
            modelPart = #","providerID":"\#(providerID)","modelID":"\#(modelID)""#
        } else {
            modelPart = ""
        }
        let costPart = cost.map { "\"cost\":\($0),"} ?? ""
        return "{\"role\":\"assistant\",\(costPart)\"tokens\":{\"total\":\(total),\"input\":\(input),\"output\":\(output),\"reasoning\":\(reasoning),\"cache\":{\"write\":\(cacheWrite),\"read\":\(cacheRead)}}\(modelPart)}"
    }

    private func scan() -> OpencodeScanner.Result {
        OpencodeScanner.scan(lastMessageTime: 0, seenMessageIds: [], databaseURL: dbURL)
    }

    // MARK: - 全量扫描

    func testFullScanParsesModelTokensAndCost() throws {
        let db = try createSchema()
        insertSession(db, id: "ses-1", title: "ccbar 对 OpenCode 用量监测探讨", directory: "/Users/nanvon/Code/cc-bar")
        insertMessage(db, id: "msg-u1", sessionID: "ses-1", timeCreated: 1_786_075_932_000, data: userMessageData())
        insertMessage(db, id: "msg-a1", sessionID: "ses-1", timeCreated: 1_786_075_934_000, data: assistantMessageData())
        insertMessage(db, id: "msg-a2", sessionID: "ses-1", timeCreated: 1_786_075_936_000,
                      data: assistantMessageData(cost: 0.00183008, input: 12_696, output: 137, reasoning: 51))
        sqlite3_close(db)

        let result = scan()

        XCTAssertEqual(result.entries.count, 2)
        XCTAssertEqual(result.newLastMessageTime, 1_786_075_936_000)
        XCTAssertEqual(result.newSeenMessageIds.count, 2)

        let first = result.entries[0]
        XCTAssertEqual(first.app, .opencode)
        XCTAssertEqual(first.conversationKey, "opencode:ses-1")
        // 模型标签从最近 user 消息继承。
        XCTAssertEqual(first.model, "opencode-go/deepseek-v4-flash")
        XCTAssertEqual(first.speed, .standard)
        XCTAssertEqual(first.inputTokens, 10_546)
        XCTAssertEqual(first.outputTokens, 18)
        XCTAssertEqual(first.cacheReadTokens, 0)
        XCTAssertEqual(first.cacheCreationTokens, 0)
        XCTAssertEqual(first.costUSD, Decimal(string: "0.00148148"))
        // 有效日志总价优先，不能被本地或在线价格表覆盖；分项总额必须与其一致。
        XCTAssertEqual(first.costBreakdown?.total, Decimal(string: "0.00148148"))
        XCTAssertGreaterThan(first.costBreakdown?.input ?? 0, 0)
        XCTAssertGreaterThan(first.costBreakdown?.output ?? 0, 0)
        XCTAssertNotEqual(first.costBreakdown?.output, first.costUSD)

        // reasoning 并入 output：137 + 51 = 188。
        let second = result.entries[1]
        XCTAssertEqual(second.outputTokens, 188)
        XCTAssertEqual(second.inputTokens, 12_696)

        // seed：官方标题 + 项目路径归一。
        XCTAssertEqual(result.conversationSeeds.count, 1)
        let seed = result.conversationSeeds[0]
        XCTAssertEqual(seed.key, "opencode:ses-1")
        XCTAssertEqual(seed.app, .opencode)
        XCTAssertEqual(seed.title, "ccbar 对 OpenCode 用量监测探讨")
        XCTAssertEqual(seed.project.path, "/Users/nanvon/Code/cc-bar")
        XCTAssertEqual(seed.project.status, .available)
    }

    func testZeroOrMissingCostFallsBackToSharedPricing() throws {
        let db = try createSchema()
        insertSession(db, id: "ses-1", title: "T1", directory: "/tmp/a")
        insertMessage(
            db,
            id: "msg-a1",
            sessionID: "ses-1",
            timeCreated: 1_786_075_934_000,
            data: assistantMessageData(
                cost: 0,
                input: 1_000,
                output: 1_000,
                providerID: "openai-codex",
                modelID: "gpt-5.5-codex"
            )
        )
        insertMessage(
            db,
            id: "msg-a2",
            sessionID: "ses-1",
            timeCreated: 1_786_075_936_000,
            data: assistantMessageData(
                cost: nil,
                input: 1_000,
                output: 1_000,
                providerID: "openai-codex",
                modelID: "gpt-5.5-codex"
            )
        )
        sqlite3_close(db)

        let result = scan()
        XCTAssertEqual(result.entries.count, 2)

        let expected = Decimal(string: "0.035")
        for entry in result.entries {
            XCTAssertEqual(entry.costUSD, expected)
            XCTAssertEqual(entry.costBreakdown?.total, expected)
        }
    }

    func testMissingCostForUnknownModelKeepsTokensAndShowsZeroCost() throws {
        let db = try createSchema()
        insertSession(db, id: "ses-1", title: "T1", directory: "/tmp/a")
        insertMessage(
            db,
            id: "msg-a1",
            sessionID: "ses-1",
            timeCreated: 1_786_075_934_000,
            data: assistantMessageData(
                cost: nil,
                input: 100,
                output: 50,
                providerID: "ccbar-test-provider",
                modelID: "ccbar-test-model-without-price-019fc5c5"
            )
        )
        sqlite3_close(db)

        let result = scan()
        let entry = try XCTUnwrap(result.entries.first)

        XCTAssertEqual(entry.inputTokens, 100)
        XCTAssertEqual(entry.outputTokens, 50)
        XCTAssertNil(entry.costUSD)
        XCTAssertNil(entry.costBreakdown)
    }

    // MARK: - 增量扫描

    func testIncrementalScanOnlyReadsNewMessages() throws {
        let db = try createSchema()
        insertSession(db, id: "ses-1", title: "T1", directory: "/tmp/a")
        insertMessage(db, id: "msg-a1", sessionID: "ses-1", timeCreated: 1_786_075_934_000,
                      data: assistantMessageData())
        sqlite3_close(db)

        let first = OpencodeScanner.scan(lastMessageTime: 0, seenMessageIds: [], databaseURL: dbURL)
        XCTAssertEqual(first.entries.count, 1)
        XCTAssertEqual(first.newLastMessageTime, 1_786_075_934_000)

        // 追加新消息后增量扫描。
        let db2 = try createSchema()
        insertMessage(db2, id: "msg-a2", sessionID: "ses-1", timeCreated: 1_786_075_940_000,
                      data: assistantMessageData(cost: 0.0005, input: 100, output: 5))
        sqlite3_close(db2)

        let second = OpencodeScanner.scan(
            lastMessageTime: first.newLastMessageTime,
            seenMessageIds: first.newSeenMessageIds,
            databaseURL: dbURL
        )
        XCTAssertEqual(second.entries.count, 1)
        XCTAssertEqual(second.entries[0].inputTokens, 100)
        XCTAssertEqual(second.newLastMessageTime, 1_786_075_940_000)
        // 旧的 seen 保留 + 新 id 加入。
        XCTAssertEqual(second.newSeenMessageIds.count, 2)
    }

    // MARK: - seen 去重（compaction / 时间戳回跳）

    func testSeenMessageIdSkipsDuplicateRows() throws {
        let db = try createSchema()
        insertSession(db, id: "ses-1", title: "T1", directory: "/tmp/a")
        insertMessage(db, id: "msg-a1", sessionID: "ses-1", timeCreated: 1_786_075_934_000,
                      data: assistantMessageData())
        sqlite3_close(db)

        let result = OpencodeScanner.scan(
            lastMessageTime: 0,
            seenMessageIds: ["msg-a1"],
            databaseURL: dbURL
        )
        XCTAssertTrue(result.entries.isEmpty)
        // 即便没产出新 entry，watermark 仍推进到已见消息。
        XCTAssertEqual(result.newLastMessageTime, 1_786_075_934_000)
    }

    // MARK: - 增量扫描只追加 assistant 时模型标签不丢失

    func testIncrementalAssistantOnlyKeepsModelLabel() throws {
        let db = try createSchema()
        insertSession(db, id: "ses-1", title: "T1", directory: "/tmp/a")
        insertMessage(db, id: "msg-u1", sessionID: "ses-1", timeCreated: 1_786_075_932_000,
                      data: userMessageData())
        insertMessage(db, id: "msg-a1", sessionID: "ses-1", timeCreated: 1_786_075_934_000,
                      data: assistantMessageData())
        sqlite3_close(db)

        let first = OpencodeScanner.scan(lastMessageTime: 0, seenMessageIds: [], databaseURL: dbURL)
        XCTAssertEqual(first.entries.count, 1)
        XCTAssertEqual(first.entries[0].model, "opencode-go/deepseek-v4-flash")

        // 只追加 assistant 消息（无新 user 消息），且该消息自身带顶层 providerID/modelID。
        let db2 = try createSchema()
        insertMessage(db2, id: "msg-a2", sessionID: "ses-1", timeCreated: 1_786_075_940_000,
                      data: assistantMessageData(cost: 0.0005, input: 100, output: 5))
        sqlite3_close(db2)

        let second = OpencodeScanner.scan(
            lastMessageTime: first.newLastMessageTime,
            seenMessageIds: first.newSeenMessageIds,
            databaseURL: dbURL
        )
        XCTAssertEqual(second.entries.count, 1)
        // 增量扫描没有读到 user 消息，模型标签来自 assistant 自身顶层字段。
        XCTAssertEqual(second.entries[0].model, "opencode-go/deepseek-v4-flash")
        XCTAssertEqual(second.entries[0].inputTokens, 100)
    }

    // MARK: - 无模型字段的 assistant 回退到会话继承

    func testAssistantWithoutModelFallsBackToSessionModel() throws {
        let db = try createSchema()
        insertSession(db, id: "ses-1", title: "T1", directory: "/tmp/a")
        insertMessage(db, id: "msg-u1", sessionID: "ses-1", timeCreated: 1_786_075_932_000,
                      data: userMessageData())
        insertMessage(db, id: "msg-a1", sessionID: "ses-1", timeCreated: 1_786_075_934_000,
                      data: assistantMessageData(providerID: nil, modelID: nil))
        sqlite3_close(db)

        let result = scan()
        XCTAssertEqual(result.entries.count, 1)
        // 全量扫描继承 user 消息模型；无顶层字段时回退成功。
        XCTAssertEqual(result.entries[0].model, "opencode-go/deepseek-v4-flash")
    }

    // MARK: - cost=0 / total=0 的消息不产生幽灵用量

    func testZeroCostZeroTokenMessageIsSkipped() throws {
        let db = try createSchema()
        insertSession(db, id: "ses-1", title: "T1", directory: "/tmp/a")
        insertMessage(db, id: "msg-u1", sessionID: "ses-1", timeCreated: 1_786_075_932_000,
                      data: userMessageData())
        // 工具调用收尾：官方 cost=0 且 tokens 全 0。
        insertMessage(db, id: "msg-a1", sessionID: "ses-1", timeCreated: 1_786_075_934_000,
                      data: assistantMessageData(cost: 0, input: 0, output: 0, reasoning: 0))
        insertMessage(db, id: "msg-a2", sessionID: "ses-1", timeCreated: 1_786_075_936_000,
                      data: assistantMessageData())
        sqlite3_close(db)

        let result = scan()
        // 只有带真实用量的 msg-a2 入账。
        XCTAssertEqual(result.entries.count, 1)
        XCTAssertEqual(result.entries[0].costUSD, Decimal(string: "0.00148148"))
    }

    // MARK: - 空标题 part 兜底

    func testEmptyTitleFallsBackToFirstTextPart() throws {
        let db = try createSchema()
        insertSession(db, id: "ses-1", title: "", directory: "/tmp/a")
        insertMessage(db, id: "msg-u1", sessionID: "ses-1", timeCreated: 1_786_075_932_000,
                      data: userMessageData())
        insertPart(db, id: "part-1", messageID: "msg-u1", sessionID: "ses-1", timeCreated: 1_786_075_932_100,
                   data: #"{"type":"text","text":"帮我重构一下登录模块","time":{"created":1786075932100}}"#)
        insertMessage(db, id: "msg-a1", sessionID: "ses-1", timeCreated: 1_786_075_934_000,
                      data: assistantMessageData())
        sqlite3_close(db)

        let result = scan()
        XCTAssertEqual(result.conversationSeeds.count, 1)
        XCTAssertEqual(result.conversationSeeds[0].title, "帮我重构一下登录模块")
    }

    // MARK: - 项目与 branch

    func testProjectAndBranchPropagation() throws {
        let db = try createSchema()
        exec(db, "INSERT INTO project (id, worktree, vcs, time_created) VALUES ('p1', '/Users/nanvon/Code/cc-bar', 'git', 1)", [])
        exec(db, "INSERT INTO workspace (id, type, name, branch, directory, project_id, time_used) VALUES ('ws-1', 'git', 'cc-bar', 'feature/opencode', '/Users/nanvon/Code/cc-bar', 'p1', 1)", [])
        insertSession(db, id: "ses-1", title: "T1", directory: "/Users/nanvon/Code/cc-bar", workspace: "ws-1")
        insertMessage(db, id: "msg-a1", sessionID: "ses-1", timeCreated: 1_786_075_934_000,
                      data: assistantMessageData())
        sqlite3_close(db)

        let result = scan()
        XCTAssertEqual(result.conversationSeeds.count, 1)
        XCTAssertEqual(result.conversationSeeds[0].gitBranch, "feature/opencode")
        XCTAssertEqual(result.conversationSeeds[0].project.path, "/Users/nanvon/Code/cc-bar")
    }

    // MARK: - 兜底 no-op

    func testMissingDatabaseIsNoOp() {
        let result = OpencodeScanner.scan(lastMessageTime: 42, seenMessageIds: ["x"], databaseURL: dbURL)
        XCTAssertTrue(result.entries.isEmpty)
        XCTAssertTrue(result.conversationSeeds.isEmpty)
        XCTAssertEqual(result.newLastMessageTime, 42)
        XCTAssertEqual(result.newSeenMessageIds, ["x"])
        XCTAssertEqual(result.messagesRead, 0)
    }

    func testCorruptDatabaseIsNoOp() throws {
        try Data("not a sqlite file".utf8).write(to: dbURL)
        let result = OpencodeScanner.scan(lastMessageTime: 0, seenMessageIds: [], databaseURL: dbURL)
        XCTAssertTrue(result.entries.isEmpty)
        XCTAssertEqual(result.newLastMessageTime, 0)
    }
}
