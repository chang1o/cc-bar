import XCTest
@testable import CCBar

/// 草案 §8.1 增量矩阵的补齐：deleted 文件 watermark 清理、archive/sessions
/// 同 ID 去重（mtime 取最新）、Claude minimumMtime 过滤。
final class ScannerIncrementalTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = Self.canonicalTempDirectory("scanner-inc")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    /// enumerator 返回的 URL 是 realpath 形式（/var → /private/var），
    /// 测试目录统一规范化，避免路径前缀差异导致 watermark key 匹配失败。
    private static func canonicalTempDirectory(_ name: String) -> URL {
        let raw = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        return raw.path.withCString { cpath in
            guard let resolved = realpath(cpath, nil) else { return raw }
            defer { free(resolved) }
            return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
        }
    }

    private func copyFixture(named name: String, to destination: URL) throws -> URL {
        let source = try XCTUnwrap(
            Bundle(for: ScannerIncrementalTests.self).url(forResource: name, withExtension: "jsonl")
        )
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
    }

    private func setMtime(_ date: Date, of url: URL) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    // MARK: - Codex

    /// 文件被删除后，下一轮扫描必须清理对应 watermark（alive 判定基于全量 key 集合）。
    func testCodexDeletedFileClearsWatermark() async throws {
        let sessions = tempDir.appendingPathComponent("sessions", isDirectory: true)
        let archived = tempDir.appendingPathComponent("archived", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: archived, withIntermediateDirectories: true)
        let id = "11111111-1111-4111-8111-111111111111"
        let file = try copyFixture(
            named: "codex-fast-scan",
            to: sessions.appendingPathComponent("rollout-2026-07-16T00-00-00-\(id).jsonl")
        )

        let first = await CodexJSONLScanner.scan(previous: [:], roots: [sessions, archived], indexedTitles: [:])
        XCTAssertEqual(first.entries.count, 3)
        XCTAssertNotNil(first.newState[id])

        try FileManager.default.removeItem(at: file)
        let second = await CodexJSONLScanner.scan(previous: first.newState, roots: [sessions, archived], indexedTitles: [:])
        XCTAssertNil(second.newState[id], "已删除会话的 watermark 应被清理")
    }

    /// sessions 与 archived_sessions 出现同 ID 会话时只取 mtime 最新的一个。
    func testCodexArchiveDedupPrefersNewestMtime() async throws {
        let sessions = tempDir.appendingPathComponent("sessions", isDirectory: true)
        let archived = tempDir.appendingPathComponent("archived", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: archived, withIntermediateDirectories: true)
        let id = "22222222-2222-4222-8222-222222222222"
        let old = try copyFixture(
            named: "codex-fast-scan",
            to: sessions.appendingPathComponent("rollout-2026-07-16T00-00-00-\(id).jsonl")
        )
        let newer = try copyFixture(
            named: "codex-fast-scan",
            to: archived.appendingPathComponent("rollout-2026-07-16T00-00-00-\(id).jsonl")
        )
        // archived 文件追加一条 token_count（4 条），并让 mtime 更新。
        let handle = try FileHandle(forWritingTo: newer)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("""
        {"timestamp":"2026-07-16T00:00:12Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":600,"cached_input_tokens":120,"output_tokens":90,"reasoning_output_tokens":12,"total_tokens":690},"last_token_usage":{"input_tokens":200,"cached_input_tokens":40,"output_tokens":35,"reasoning_output_tokens":4,"total_tokens":235}}}}

        """.utf8))
        try handle.close()
        try setMtime(Date(timeIntervalSince1970: 1_000), of: old)
        try setMtime(Date(timeIntervalSince1970: 2_000), of: newer)

        let result = await CodexJSONLScanner.scan(previous: [:], roots: [sessions, archived], indexedTitles: [:])
        XCTAssertEqual(result.filesScanned, 1, "同 ID 会话只应解析最新的一份")
        XCTAssertEqual(result.entries.count, 4, "应解析 mtime 更新的 archived 文件（含追加行）")
    }

    /// 反向：mtime 更旧的一方胜出时同样只解析一份。
    func testCodexArchiveDedupPrefersNewestMtimeReversed() async throws {
        let sessions = tempDir.appendingPathComponent("sessions", isDirectory: true)
        let archived = tempDir.appendingPathComponent("archived", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: archived, withIntermediateDirectories: true)
        let id = "33333333-3333-4333-8333-333333333333"
        let old = try copyFixture(
            named: "codex-fast-scan",
            to: archived.appendingPathComponent("rollout-2026-07-16T00-00-00-\(id).jsonl")
        )
        let newer = try copyFixture(
            named: "codex-fast-scan",
            to: sessions.appendingPathComponent("rollout-2026-07-16T00-00-00-\(id).jsonl")
        )
        let handle = try FileHandle(forWritingTo: newer)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("""
        {"timestamp":"2026-07-16T00:00:12Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":600,"cached_input_tokens":120,"output_tokens":90,"reasoning_output_tokens":12,"total_tokens":690},"last_token_usage":{"input_tokens":200,"cached_input_tokens":40,"output_tokens":35,"reasoning_output_tokens":4,"total_tokens":235}}}}

        """.utf8))
        try handle.close()
        try setMtime(Date(timeIntervalSince1970: 1_000), of: old)
        try setMtime(Date(timeIntervalSince1970: 2_000), of: newer)

        let result = await CodexJSONLScanner.scan(previous: [:], roots: [sessions, archived], indexedTitles: [:])
        XCTAssertEqual(result.filesScanned, 1)
        XCTAssertEqual(result.entries.count, 4, "mtime 新的 sessions 文件应胜出")
    }

    /// 受限重建按 mtime 过滤两个根目录：平铺归档和旧日期目录中续用的会话都不能漏扫。
    func testCodexMinimumMtimeIncludesFlatArchiveAndResumedOldSession() async throws {
        let sessions = tempDir.appendingPathComponent("sessions", isDirectory: true)
        let oldDatedSessions = sessions.appendingPathComponent("2020/01/01", isDirectory: true)
        let archived = tempDir.appendingPathComponent("archived_sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: oldDatedSessions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: archived, withIntermediateDirectories: true)
        let resumedID = "44444444-4444-4444-8444-444444444444"
        let archivedID = "55555555-5555-4555-8555-555555555555"
        let staleID = "66666666-6666-4666-8666-666666666666"
        let resumed = try copyFixture(
            named: "codex-fast-scan",
            to: oldDatedSessions.appendingPathComponent("rollout-2020-01-01T00-00-00-\(resumedID).jsonl")
        )
        let flatArchive = try copyFixture(
            named: "codex-fast-scan",
            to: archived.appendingPathComponent("rollout-2026-08-17T00-00-00-\(archivedID).jsonl")
        )
        let stale = try copyFixture(
            named: "codex-fast-scan",
            to: sessions.appendingPathComponent("rollout-2026-08-01T00-00-00-\(staleID).jsonl")
        )
        try setMtime(Date(timeIntervalSince1970: 2_000), of: resumed)
        try setMtime(Date(timeIntervalSince1970: 2_100), of: flatArchive)
        try setMtime(Date(timeIntervalSince1970: 1_000), of: stale)

        let result = await CodexJSONLScanner.scan(
            previous: [:],
            roots: [sessions, archived],
            indexedTitles: [:],
            minimumMtime: Date(timeIntervalSince1970: 1_500)
        )

        XCTAssertEqual(result.filesScanned, 2)
        XCTAssertNotNil(result.newState[resumedID], "旧日期目录中近期续用的会话应被扫描")
        XCTAssertNotNil(result.newState[archivedID], "平铺 archived_sessions 文件应被扫描")
        XCTAssertNil(result.newState[staleID])
    }

    func testCodexReportsUnreadableJSONLWithoutAdvancingItsWatermark() async throws {
        let sessions = tempDir.appendingPathComponent("sessions", isDirectory: true)
        let archived = tempDir.appendingPathComponent("archived", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: archived, withIntermediateDirectories: true)
        let id = "77777777-7777-4777-8777-777777777777"
        let file = try copyFixture(
            named: "codex-fast-scan",
            to: sessions.appendingPathComponent("rollout-2026-08-19T00-00-00-\(id).jsonl")
        )
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }

        let result = await CodexJSONLScanner.scan(
            previous: [:],
            roots: [sessions, archived],
            indexedTitles: [:]
        )

        XCTAssertEqual(result.failedFileCount, 1)
        XCTAssertEqual(result.newState[id]?.offset, 0, "读失败文件必须保留可重试的 watermark")
    }

    func testMissingRootsAreEmptyWhileInvalidRootsAreFailures() async throws {
        let missingClaude = tempDir.appendingPathComponent("missing-claude", isDirectory: true)
        let claude = ClaudeJSONLScanner.scan(
            previous: [:],
            seenMessageIds: [],
            root: missingClaude,
            conversationIndex: ConversationTitleIndex.ClaudeIndex(titles: [:], projects: [:])
        )
        let codex = await CodexJSONLScanner.scan(
            previous: [:],
            roots: [
                tempDir.appendingPathComponent("missing-codex-sessions", isDirectory: true),
                tempDir.appendingPathComponent("missing-codex-archive", isDirectory: true),
            ],
            indexedTitles: [:]
        )

        XCTAssertEqual(claude.failedFileCount, 0)
        XCTAssertEqual(codex.failedFileCount, 0)
        XCTAssertTrue(claude.entries.isEmpty)
        XCTAssertTrue(codex.entries.isEmpty)

        let notDirectory = tempDir.appendingPathComponent("not-a-directory")
        try Data().write(to: notDirectory)
        let invalidClaude = ClaudeJSONLScanner.scan(
            previous: [:],
            seenMessageIds: [],
            root: notDirectory,
            conversationIndex: ConversationTitleIndex.ClaudeIndex(titles: [:], projects: [:])
        )
        let invalidCodex = await CodexJSONLScanner.scan(
            previous: [:],
            roots: [notDirectory],
            indexedTitles: [:]
        )

        XCTAssertEqual(invalidClaude.failedFileCount, 1)
        XCTAssertEqual(invalidCodex.failedFileCount, 1)
    }

    func testJSONLReadOutcomeTreatsEnumeratedThenRemovedFileAsMissing() throws {
        let root = tempDir.appendingPathComponent("enumeration-race", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("session.jsonl")
        try Data("{}\n".utf8).write(to: file)
        let descriptor = try XCTUnwrap(JSONLDirectoryEnumerator.enumerate(at: root).files.first)

        try FileManager.default.removeItem(at: file)

        guard case .missing = JSONLLineReader.readOutcome(url: descriptor.url, fromOffset: 0) else {
            return XCTFail("枚举后被移动或删除的文件应视为正常消失，不是读取失败")
        }
    }

    // MARK: - Codex fork 重放去重

    private static let forkParentID = "019daa2f-0000-7000-8000-000000000001"
    private static let forkChildID = "019daa54-0000-7000-8000-000000000002"
    private static let forkFreshID = "019daa77-0000-7000-8000-000000000003"

    /// 三条真实调用；子会话 fork 时会把它们原样重放进自己的 JSONL。
    private static func forkParentBody() -> String {
        """
        {"timestamp":"2026-07-16T00:00:00Z","type":"session_meta","payload":{"id":"\(forkParentID)","cwd":"/tmp/ccbar-fixture"}}
        {"timestamp":"2026-07-16T00:00:01Z","type":"turn_context","payload":{"model":"gpt-5.6-sol"}}
        {"timestamp":"2026-07-16T00:00:02Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":10,"reasoning_output_tokens":2,"total_tokens":110},"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":10,"reasoning_output_tokens":2,"total_tokens":110}}}}
        {"timestamp":"2026-07-16T00:00:03Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":250,"cached_input_tokens":50,"output_tokens":30,"reasoning_output_tokens":5,"total_tokens":280},"last_token_usage":{"input_tokens":150,"cached_input_tokens":30,"output_tokens":20,"reasoning_output_tokens":3,"total_tokens":170}}}}
        {"timestamp":"2026-07-16T00:00:04Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":350,"cached_input_tokens":70,"output_tokens":45,"reasoning_output_tokens":7,"total_tokens":395},"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":15,"reasoning_output_tokens":2,"total_tokens":115}}}}

        """
    }

    /// 真实 fork 文件的形状：自身 session_meta（带 forked_from_id）→ 父会话 session_meta 原样重放
    /// → 父会话全部 token_count 原样重放（只改写 timestamp）→ fork 之后的新调用。
    /// 关键点是新调用之后**不会**再写一条自身的 session_meta，因此它们同样处在父会话 id 之下。
    private static func forkChildBody() -> String {
        """
        {"timestamp":"2026-07-16T01:00:00Z","type":"session_meta","payload":{"id":"\(forkChildID)","forked_from_id":"\(forkParentID)","cwd":"/tmp/ccbar-fixture"}}
        {"timestamp":"2026-07-16T01:00:00Z","type":"session_meta","payload":{"id":"\(forkParentID)","cwd":"/tmp/ccbar-fixture"}}
        {"timestamp":"2026-07-16T01:00:00Z","type":"turn_context","payload":{"model":"gpt-5.6-sol"}}
        {"timestamp":"2026-07-16T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":10,"reasoning_output_tokens":2,"total_tokens":110},"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":10,"reasoning_output_tokens":2,"total_tokens":110}}}}
        {"timestamp":"2026-07-16T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":250,"cached_input_tokens":50,"output_tokens":30,"reasoning_output_tokens":5,"total_tokens":280},"last_token_usage":{"input_tokens":150,"cached_input_tokens":30,"output_tokens":20,"reasoning_output_tokens":3,"total_tokens":170}}}}
        {"timestamp":"2026-07-16T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":350,"cached_input_tokens":70,"output_tokens":45,"reasoning_output_tokens":7,"total_tokens":395},"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":15,"reasoning_output_tokens":2,"total_tokens":115}}}}
        {"timestamp":"2026-07-16T01:05:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":470,"cached_input_tokens":95,"output_tokens":63,"reasoning_output_tokens":9,"total_tokens":533},"last_token_usage":{"input_tokens":120,"cached_input_tokens":25,"output_tokens":18,"reasoning_output_tokens":2,"total_tokens":138}}}}
        {"timestamp":"2026-07-16T01:10:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":585,"cached_input_tokens":115,"output_tokens":79,"reasoning_output_tokens":11,"total_tokens":664},"last_token_usage":{"input_tokens":115,"cached_input_tokens":20,"output_tokens":16,"reasoning_output_tokens":2,"total_tokens":131}}}}

        """
    }

    /// 同样带 forked_from_id，但 Codex 没有重放任何历史（累计值从 0 起算）——真实日志里存在这种
    /// fork。按 forked_from_id 一刀切排除会把它整段真实用量删掉。
    private static func forkFreshBody() -> String {
        """
        {"timestamp":"2026-07-16T02:00:00Z","type":"session_meta","payload":{"id":"\(forkFreshID)","forked_from_id":"\(forkParentID)","cwd":"/tmp/ccbar-fixture"}}
        {"timestamp":"2026-07-16T02:00:01Z","type":"turn_context","payload":{"model":"gpt-5.6-sol"}}
        {"timestamp":"2026-07-16T02:00:02Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":80,"cached_input_tokens":10,"output_tokens":10,"reasoning_output_tokens":1,"total_tokens":90},"last_token_usage":{"input_tokens":80,"cached_input_tokens":10,"output_tokens":10,"reasoning_output_tokens":1,"total_tokens":90}}}}

        """
    }

    @discardableResult
    private func writeSession(_ body: String, id: String, at hour: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("rollout-2026-07-16T\(hour)-00-00-\(id).jsonl")
        try Data(body.utf8).write(to: url)
        return url
    }

    /// fork 会话重放的父会话历史不能重复计费，fork 之后的新调用必须照常入账，
    /// 且新调用要归到 fork 自己的会话 key（旧实现会被重放进来的父 session_meta 串走）。
    func testCodexForkReplayNotDoubleCounted() async throws {
        let sessions = tempDir.appendingPathComponent("sessions", isDirectory: true)
        let archived = tempDir.appendingPathComponent("archived", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: archived, withIntermediateDirectories: true)
        try writeSession(Self.forkParentBody(), id: Self.forkParentID, at: "00", in: sessions)
        try writeSession(Self.forkChildBody(), id: Self.forkChildID, at: "01", in: sessions)

        let result = await CodexJSONLScanner.scan(previous: [:], roots: [sessions, archived], indexedTitles: [:])

        XCTAssertEqual(result.entries.count, 5, "父会话 3 条 + fork 后新增 2 条，重放的 3 条必须被去掉")
        let parentEntries = result.entries.filter { $0.conversationKey == "codex:\(Self.forkParentID)" }
        let childEntries = result.entries.filter { $0.conversationKey == "codex:\(Self.forkChildID)" }
        XCTAssertEqual(parentEntries.count, 3)
        XCTAssertEqual(childEntries.count, 2, "fork 之后的新调用应归到 fork 自己的会话")
        XCTAssertEqual(childEntries.map(\.inputTokens).sorted(), [95, 95])
        XCTAssertEqual(childEntries.map(\.outputTokens).sorted(), [16, 18])
        // 重放行的 timestamp 被改写成 fork 时刻；保留下来的必须是父文件里的原始时间。
        XCTAssertTrue(
            parentEntries.allSatisfy { $0.timestamp < Date(timeIntervalSince1970: 1_784_161_800) },
            "保留的应是父文件里带原始时间的记录，而不是 fork 时刻的副本"
        )
    }

    /// 扫描顺序不能影响结果：父会话按 UUIDv7 排序永远先于它的 fork。
    /// 若顺序漂移，被保留的会变成 timestamp 已被改写的重放副本，用量会归错天。
    func testCodexForkDedupIsOrderIndependent() async throws {
        let sessions = tempDir.appendingPathComponent("sessions", isDirectory: true)
        let archived = tempDir.appendingPathComponent("archived", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: archived, withIntermediateDirectories: true)
        // 先写 fork，再写父会话，让目录枚举顺序与会话创建顺序相反。
        try writeSession(Self.forkChildBody(), id: Self.forkChildID, at: "01", in: sessions)
        try writeSession(Self.forkParentBody(), id: Self.forkParentID, at: "00", in: sessions)

        let result = await CodexJSONLScanner.scan(previous: [:], roots: [sessions, archived], indexedTitles: [:])

        XCTAssertEqual(result.entries.count, 5)
        XCTAssertEqual(result.entries.filter { $0.conversationKey == "codex:\(Self.forkParentID)" }.count, 3)
    }

    /// 带 forked_from_id 但没有重放历史的 fork，用量一条都不能少。
    func testCodexForkWithoutReplayKeepsAllUsage() async throws {
        let sessions = tempDir.appendingPathComponent("sessions", isDirectory: true)
        let archived = tempDir.appendingPathComponent("archived", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: archived, withIntermediateDirectories: true)
        try writeSession(Self.forkParentBody(), id: Self.forkParentID, at: "00", in: sessions)
        try writeSession(Self.forkFreshBody(), id: Self.forkFreshID, at: "02", in: sessions)

        let result = await CodexJSONLScanner.scan(previous: [:], roots: [sessions, archived], indexedTitles: [:])

        XCTAssertEqual(result.entries.count, 4)
        XCTAssertEqual(result.entries.filter { $0.conversationKey == "codex:\(Self.forkFreshID)" }.count, 1)
    }

    /// 增量场景：父会话上一轮已扫完，本轮才出现 fork 文件——去重必须靠持久化的 seen 集合。
    func testCodexForkReplayDedupedAcrossIncrementalScans() async throws {
        let sessions = tempDir.appendingPathComponent("sessions", isDirectory: true)
        let archived = tempDir.appendingPathComponent("archived", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: archived, withIntermediateDirectories: true)
        try writeSession(Self.forkParentBody(), id: Self.forkParentID, at: "00", in: sessions)

        let first = await CodexJSONLScanner.scan(previous: [:], roots: [sessions, archived], indexedTitles: [:])
        XCTAssertEqual(first.entries.count, 3)
        XCTAssertEqual(first.newSeenIds.count, 3)

        try writeSession(Self.forkChildBody(), id: Self.forkChildID, at: "01", in: sessions)
        let second = await CodexJSONLScanner.scan(
            previous: first.newState,
            seenTokenIds: first.newSeenIds,
            roots: [sessions, archived],
            indexedTitles: [:]
        )

        XCTAssertEqual(second.entries.count, 2, "重放段已在上一轮记入 seen，本轮只应收到 fork 后的新调用")
        XCTAssertTrue(second.entries.allSatisfy { $0.conversationKey == "codex:\(Self.forkChildID)" })
    }

    // MARK: - Claude

    /// Claude 同样按 alive 清理已删除文件的 watermark。
    func testClaudeDeletedFileClearsWatermark() throws {
        let projects = tempDir.appendingPathComponent("projects", isDirectory: true)
        let container = projects.appendingPathComponent("fixture-project", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        let file = try copyFixture(
            named: "claude-fast-scan",
            to: container.appendingPathComponent("session-a.jsonl")
        )
        let index = ConversationTitleIndex.ClaudeIndex(titles: [:], projects: [:])

        let first = ClaudeJSONLScanner.scan(previous: [:], seenMessageIds: [], root: projects, conversationIndex: index)
        XCTAssertFalse(first.entries.isEmpty)
        XCTAssertNotNil(first.newState[file.path])

        try FileManager.default.removeItem(at: file)
        let second = ClaudeJSONLScanner.scan(previous: first.newState, seenMessageIds: [], root: projects, conversationIndex: index)
        XCTAssertNil(second.newState[file.path], "已删除文件的 watermark 应被清理")
    }

    /// minimumMtime 只返回窗口内的文件（周期受限重建语义）。
    func testClaudeMinimumMtimeFiltersOldFiles() throws {
        let projects = tempDir.appendingPathComponent("projects", isDirectory: true)
        let c1 = projects.appendingPathComponent("p1", isDirectory: true)
        let c2 = projects.appendingPathComponent("p2", isDirectory: true)
        try FileManager.default.createDirectory(at: c1, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: c2, withIntermediateDirectories: true)
        let old = try copyFixture(named: "claude-fast-scan", to: c1.appendingPathComponent("old.jsonl"))
        let newer = try copyFixture(named: "claude-fast-scan", to: c2.appendingPathComponent("new.jsonl"))
        try setMtime(Date(timeIntervalSince1970: 1_000), of: old)
        try setMtime(Date(timeIntervalSince1970: 2_000), of: newer)
        let index = ConversationTitleIndex.ClaudeIndex(titles: [:], projects: [:])

        let filtered = ClaudeJSONLScanner.scan(
            previous: [:],
            seenMessageIds: [],
            root: projects,
            conversationIndex: index,
            minimumMtime: Date(timeIntervalSince1970: 1_500)
        )
        XCTAssertEqual(filtered.filesScanned, 1)
        XCTAssertNil(filtered.newState[old.path])
        XCTAssertNotNil(filtered.newState[newer.path])
    }
}
