import XCTest
import CryptoKit
@testable import CCBar

/// 草案 §8.2：结果等价对照。
///
/// 两层：
/// - 固定场景：同一 fixture 目录连扫两遍，摘要必须逐字一致（确定性校验），
///   任何"扫描路径"重构（如批次 B/C）都不能改变输出。
/// - 真实目录模式（手动）：环境变量 `CCBAR_COMPARE_ROOT` 指向只读日志根目录，
///   结构约定：
///     {root}/codex-sessions/  codex-archived/  claude-projects/  pi-sessions/  opencode.db
///   输出四 Scanner 摘要；`CCBAR_GOLDEN_UPDATE=1` 写 golden 文件，否则与 golden 对比。
///   未设置环境变量时整类跳过，不影响 CI。
final class UsageEquivalenceTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("usage-equiv-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    // MARK: - 摘要行生成（稳定、无时间戳）

    private static func digest(_ values: [String]) -> String {
        let joined = values.joined(separator: ",")
        let hash = SHA256.hash(data: Data(joined.utf8))
        return hash.map { String(format: "%02x", $0) }.prefix(16).joined()
    }

    private static func summaryLine(
        app: String,
        filesScanned: Int,
        entries: Int,
        linesParsed: Int,
        inputTokens: Int,
        outputTokens: Int,
        cacheReadTokens: Int,
        cacheCreationTokens: Int,
        cost: Decimal,
        seeds: Int,
        keys: [String],
        statePairs: [(String, UInt64)]
    ) -> String {
        let keyDigest = digest(keys.sorted())
        let stateDigest = digest(statePairs.map { "\($0.0):\($0.1)" }.sorted())
        return [
            app,
            "files=\(filesScanned)",
            "entries=\(entries)",
            "lines=\(linesParsed)",
            "tokens=\(inputTokens)/\(outputTokens)/\(cacheReadTokens)/\(cacheCreationTokens)",
            "cost=\(cost)",
            "seeds=\(seeds)",
            "keys=\(keyDigest)",
            "state=\(stateDigest)",
        ].joined(separator: " ")
    }

    private static func codexSummary(_ result: CodexJSONLScanner.Result) -> String {
        summaryLine(
            app: "codex",
            filesScanned: result.filesScanned,
            entries: result.entries.count,
            linesParsed: result.linesParsed,
            inputTokens: result.entries.reduce(0) { $0 + $1.inputTokens },
            outputTokens: result.entries.reduce(0) { $0 + $1.outputTokens },
            cacheReadTokens: result.entries.reduce(0) { $0 + $1.cacheReadTokens },
            cacheCreationTokens: result.entries.reduce(0) { $0 + $1.cacheCreationTokens },
            cost: result.entries.compactMap(\.costUSD).reduce(0, +),
            seeds: result.conversationSeeds.count,
            keys: result.entries.map(\.conversationKey),
            statePairs: result.newState.map { ($0.key, $0.value.offset) }
        )
    }

    private static func claudeSummary(_ result: ClaudeJSONLScanner.Result) -> String {
        summaryLine(
            app: "claude",
            filesScanned: result.filesScanned,
            entries: result.entries.count,
            linesParsed: result.linesParsed,
            inputTokens: result.entries.reduce(0) { $0 + $1.inputTokens },
            outputTokens: result.entries.reduce(0) { $0 + $1.outputTokens },
            cacheReadTokens: result.entries.reduce(0) { $0 + $1.cacheReadTokens },
            cacheCreationTokens: result.entries.reduce(0) { $0 + $1.cacheCreationTokens },
            cost: result.entries.compactMap(\.costUSD).reduce(0, +),
            seeds: result.conversationSeeds.count,
            keys: result.entries.map(\.conversationKey),
            statePairs: result.newState.map { ($0.key, $0.value.offset) }
        )
    }

    private static func piSummary(_ result: PiJSONLScanner.Result) -> String {
        summaryLine(
            app: "pi",
            filesScanned: result.filesScanned,
            entries: result.entries.count,
            linesParsed: result.linesParsed,
            inputTokens: result.entries.reduce(0) { $0 + $1.inputTokens },
            outputTokens: result.entries.reduce(0) { $0 + $1.outputTokens },
            cacheReadTokens: result.entries.reduce(0) { $0 + $1.cacheReadTokens },
            cacheCreationTokens: result.entries.reduce(0) { $0 + $1.cacheCreationTokens },
            cost: result.entries.compactMap(\.costUSD).reduce(0, +),
            seeds: result.conversationSeeds.count,
            keys: result.entries.map(\.conversationKey),
            statePairs: result.newState.map { ($0.key, $0.value.offset) }
        )
    }

    // MARK: - 固定场景：连扫两遍逐字一致

    func testFixtureScanIsDeterministicAcrossRuns() async throws {
        let sessions = tempDir.appendingPathComponent("sessions", isDirectory: true)
        let archived = tempDir.appendingPathComponent("archived", isDirectory: true)
        let projects = tempDir.appendingPathComponent("projects", isDirectory: true)
        let container = projects.appendingPathComponent("fixture-project", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: archived, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        let id = "44444444-4444-4444-8444-444444444444"
        try copyFixture(
            named: "codex-fast-scan",
            to: sessions.appendingPathComponent("rollout-2026-07-16T00-00-00-\(id).jsonl")
        )
        try copyFixture(
            named: "claude-fast-scan",
            to: container.appendingPathComponent("claude-session.jsonl")
        )

        // 同一数据连跑两遍全量，摘要必须逐字一致（确定性校验）。
        let codexFirst = await CodexJSONLScanner.scan(previous: [:], roots: [sessions, archived], indexedTitles: [:])
        let codexSecond = await CodexJSONLScanner.scan(previous: [:], roots: [sessions, archived], indexedTitles: [:])
        XCTAssertEqual(Self.codexSummary(codexFirst), Self.codexSummary(codexSecond))
        XCTAssertEqual(codexFirst.entries.count, 3)

        // 增量扫描（无变化）：不产出新 entries，ScanState 摘要与全量一致（批次 B 快速路径）。
        let codexIncremental = await CodexJSONLScanner.scan(previous: codexFirst.newState, roots: [sessions, archived], indexedTitles: [:])
        XCTAssertTrue(codexIncremental.entries.isEmpty)
        XCTAssertEqual(codexIncremental.linesParsed, 0)
        XCTAssertEqual(Self.codexStateDigest(codexFirst), Self.codexStateDigest(codexIncremental))

        let index = ConversationTitleIndex.ClaudeIndex(titles: [:], projects: [:])
        let claudeFirst = ClaudeJSONLScanner.scan(previous: [:], seenMessageIds: [], root: projects, conversationIndex: index)
        let claudeSecond = ClaudeJSONLScanner.scan(previous: [:], seenMessageIds: [], root: projects, conversationIndex: index)
        XCTAssertEqual(Self.claudeSummary(claudeFirst), Self.claudeSummary(claudeSecond))
        XCTAssertFalse(claudeFirst.entries.isEmpty)
    }

    private static func codexStateDigest(_ result: CodexJSONLScanner.Result) -> String {
        digest(result.newState.map { "\($0.key):\($0.value.offset)" }.sorted())
    }

    // MARK: - 真实目录对照（手动模式）

    /// 对照配置。hosted 测试进程拿不到 shell 环境变量（xcodebuild 不传递），
    /// 统一从 `~/.ccbar/usage-equivalence.json` 读取：
    ///     {"compareRoot": "...", "goldenDir": "...", "update": true|false}
    /// 没有该文件时整类跳过，不影响 CI。
    private struct GoldenConfig: Decodable {
        var compareRoot: String
        var goldenDir: String
        var update: Bool
    }

    private static var config: GoldenConfig? {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ccbar/usage-equivalence.json").path
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let config = try? JSONDecoder().decode(GoldenConfig.self, from: data)
        else { return nil }
        return config
    }

    func testRealDataEquivalenceAgainstGolden() async throws {
        guard let config = Self.config else {
            throw XCTSkip("未配置 ~/.ccbar/usage-equivalence.json，跳过真实数据对照")
        }
        // FileManager.enumerator 不跟随 root 自身为符号链接的目录（实测返回空），
        // 统一解析到真实路径再枚举；配置目录用符号链接指向真实日志时也能工作。
        let rootURL = URL(fileURLWithPath: config.compareRoot, isDirectory: true)
            .resolvingSymlinksInPath()
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: rootURL.path, isDirectory: &isDir), isDir.boolValue else {
            throw XCTSkip("CCBAR_COMPARE_ROOT 不是有效目录")
        }

        var lines: [String] = []

        // Codex
        var codexRoots: [URL] = []
        for name in ["codex-sessions", "codex-archived"] {
            let dir = rootURL.appendingPathComponent(name, isDirectory: true)
                .resolvingSymlinksInPath()
            if fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue {
                codexRoots.append(dir)
            }
        }
        if !codexRoots.isEmpty {
            let result = await CodexJSONLScanner.scan(previous: [:], roots: codexRoots, indexedTitles: [:])
            lines.append(Self.codexSummary(result))
        }

        // Claude
        let claudeDir = rootURL.appendingPathComponent("claude-projects", isDirectory: true)
            .resolvingSymlinksInPath()
        if fm.fileExists(atPath: claudeDir.path, isDirectory: &isDir), isDir.boolValue {
            let index = ConversationTitleIndex.ClaudeIndex(titles: [:], projects: [:])
            let result = ClaudeJSONLScanner.scan(previous: [:], seenMessageIds: [], root: claudeDir, conversationIndex: index)
            lines.append(Self.claudeSummary(result))
        }

        // Pi
        let piDir = rootURL.appendingPathComponent("pi-sessions", isDirectory: true)
            .resolvingSymlinksInPath()
        if fm.fileExists(atPath: piDir.path, isDirectory: &isDir), isDir.boolValue {
            let result = PiJSONLScanner.scan(previous: [:], seenEntryIds: [], root: piDir)
            lines.append(Self.piSummary(result))
        }

        // OpenCode
        let opencodeDB = rootURL.appendingPathComponent("opencode.db", isDirectory: false)
            .resolvingSymlinksInPath()
        if fm.fileExists(atPath: opencodeDB.path) {
            let result = OpencodeScanner.scan(lastMessageTime: 0, seenMessageIds: [], databaseURL: opencodeDB)
            lines.append(Self.opencodeSummary(result))
        }

        lines.sort()
        let golden = config.goldenDir + "/usage-equivalence.txt"
        if config.update {
            try lines.joined(separator: "\n").write(
                toFile: golden,
                atomically: true,
                encoding: .utf8
            )
            return
        }
        // opencode.db 是活跃 SQLite 库，两次运行之间可能有新消息写入，
        // 不参与严格对比；claude / codex / pi 为追加式 JSONL，基线稳定。
        let comparable = lines.filter { !$0.hasPrefix("opencode ") }
        let expected = try String(contentsOfFile: golden, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
            .filter { !$0.hasPrefix("opencode ") }
        XCTAssertEqual(comparable, expected, "真实数据摘要与 golden 不一致；若属有意变更，用 CCBAR_GOLDEN_UPDATE=1 重新生成基线")
    }

    private static func opencodeSummary(_ result: OpencodeScanner.Result) -> String {
        let statePairs: [(String, UInt64)] = []
        return summaryLine(
            app: "opencode",
            filesScanned: result.messagesRead,
            entries: result.entries.count,
            linesParsed: 0,
            inputTokens: result.entries.reduce(0) { $0 + $1.inputTokens },
            outputTokens: result.entries.reduce(0) { $0 + $1.outputTokens },
            cacheReadTokens: result.entries.reduce(0) { $0 + $1.cacheReadTokens },
            cacheCreationTokens: result.entries.reduce(0) { $0 + $1.cacheCreationTokens },
            cost: result.entries.compactMap(\.costUSD).reduce(0, +),
            seeds: result.conversationSeeds.count,
            keys: result.entries.map(\.conversationKey),
            statePairs: statePairs
        )
    }

    private func copyFixture(named name: String, to destination: URL) throws {
        let source = try XCTUnwrap(
            Bundle(for: UsageEquivalenceTests.self).url(forResource: name, withExtension: "jsonl")
        )
        try FileManager.default.copyItem(at: source, to: destination)
    }
}
