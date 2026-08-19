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
