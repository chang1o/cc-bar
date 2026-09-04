import XCTest
@testable import CCBar

/// ConversationProjectResolver 的隐私分级：
/// 只有家目录以内、且不在 TCC 保护目录（桌面/文稿/下载/音乐/图片/影片）之下的路径
/// 才允许做文件系统检查；其余路径（可移动卷、网络宗卷、其他用户目录）一律按字符串
/// 归组为 .unverified，绝不触发系统“文件与文件夹”授权弹窗。
final class ConversationProjectResolverTests: XCTestCase {
    private let home = "/Users/tester"

    // MARK: - 分级判定

    func testAllowsCheckInOrdinaryHomeFolder() {
        XCTAssertTrue(ConversationProjectResolver.allowsFileSystemCheck(
            standardizedPath: "/Users/tester/Code/cc-bar", home: home))
        XCTAssertTrue(ConversationProjectResolver.allowsFileSystemCheck(
            standardizedPath: "/Users/tester/work/demo", home: home))
    }

    func testDeniesCheckInProtectedFolders() {
        for folder in ["Desktop", "Documents", "Downloads", "Music", "Pictures", "Movies"] {
            XCTAssertFalse(
                ConversationProjectResolver.allowsFileSystemCheck(
                    standardizedPath: "/Users/tester/\(folder)/project", home: home),
                folder)
            XCTAssertFalse(
                ConversationProjectResolver.allowsFileSystemCheck(
                    standardizedPath: "/Users/tester/\(folder)", home: home),
                "受保护目录本身也不能 stat：\(folder)")
        }
    }

    func testProtectedFolderMatchIsComponentWise() {
        // DocumentsExtra 不是受保护目录，不能被 “Documents” 前缀误伤。
        XCTAssertTrue(ConversationProjectResolver.allowsFileSystemCheck(
            standardizedPath: "/Users/tester/DocumentsExtra/project", home: home))
    }

    func testDeniesCheckOutsideHome() {
        XCTAssertFalse(ConversationProjectResolver.allowsFileSystemCheck(
            standardizedPath: "/Volumes/Backup/project", home: home))
        XCTAssertFalse(ConversationProjectResolver.allowsFileSystemCheck(
            standardizedPath: "/Users/other/Documents/project", home: home))
        XCTAssertFalse(ConversationProjectResolver.allowsFileSystemCheck(
            standardizedPath: "/tmp/demo", home: home))
    }

    func testDeniesCheckIsCaseInsensitive() {
        XCTAssertFalse(ConversationProjectResolver.allowsFileSystemCheck(
            standardizedPath: "/Users/tester/documents/project", home: home))
        XCTAssertFalse(ConversationProjectResolver.allowsFileSystemCheck(
            standardizedPath: "/users/TESTER/Music/x", home: home))
    }

    // MARK: - resolve 行为

    func testResolveProtectedPathSkipsFileSystem() {
        var resolver = ConversationProjectResolver(home: home)
        // 路径在假的 home 下必然不存在；若实现误做 stat，会得到 .unavailable 而非 .unverified。
        let project = resolver.resolve(rawPath: "/Users/tester/Documents/missing-project", source: .cwd)
        XCTAssertEqual(project.status, .unverified)
        XCTAssertEqual(project.name, "missing-project")
        XCTAssertEqual(project.key, "path:/Users/tester/Documents/missing-project")
        XCTAssertEqual(project.path, "/Users/tester/Documents/missing-project")
        XCTAssertEqual(project.source, .cwd)
    }

    func testResolveOrdinaryPathChecksExistenceAndGitRoot() throws {
        let homeURL = FileManager.default.homeDirectoryForCurrentUser
        let base = homeURL
            .appendingPathComponent("Library/Caches/CCBarResolverTests-\(UUID().uuidString)", isDirectory: true)
        let repo = base.appendingPathComponent("repo")
        let nested = repo.appendingPathComponent("packages/app")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        var resolver = ConversationProjectResolver(home: homeURL.standardizedFileURL.path)
        let project = resolver.resolve(rawPath: nested.path, source: .cwd)
        XCTAssertEqual(project.status, .available)
        XCTAssertEqual(project.path, repo.standardizedFileURL.path)
        XCTAssertEqual(project.name, "repo")
        XCTAssertEqual(project.source, .gitRoot)
    }

    func testResolveMissingOrdinaryPathReportsUnavailable() throws {
        let homeURL = FileManager.default.homeDirectoryForCurrentUser
        let missing = homeURL
            .appendingPathComponent("Library/Caches/CCBarResolverTests-missing-\(UUID().uuidString)/demo")
        var resolver = ConversationProjectResolver(home: homeURL.standardizedFileURL.path)
        let project = resolver.resolve(rawPath: missing.path, source: .cwd)
        XCTAssertEqual(project.status, .unavailable)
    }

    func testResolveHomeItselfStaysUnassigned() {
        var resolver = ConversationProjectResolver(home: home)
        XCTAssertEqual(resolver.resolve(rawPath: home, source: .cwd), .unassigned)
        XCTAssertEqual(resolver.resolve(rawPath: "/", source: .cwd), .unassigned)
    }
}
