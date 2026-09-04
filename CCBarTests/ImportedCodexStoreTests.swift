import XCTest
@testable import CCBar

/// 草案 §4.2：镜像导入账号 token 只在内容变化时写 Keychain。
/// 测试使用随机 accountId 并始终清理，避免污染真实 Keychain。
final class ImportedCodexStoreTests: XCTestCase {
    private func makeTokens(access: String = "access-1", refresh: String? = "refresh-1", id: String? = "id-1") -> ImportedCodexTokens {
        ImportedCodexTokens(accessToken: access, refreshToken: refresh, idToken: id)
    }

    func testSaveTokensIfChangedSkipsIdenticalContent() throws {
        let accountId = "test-same-\(UUID().uuidString)"
        defer { ImportedCodexStore.deleteTokens(accountId: accountId) }
        let tokens = makeTokens()
        try ImportedCodexStore.saveTokens(tokens, accountId: accountId)

        let written = try ImportedCodexStore.saveTokensIfChanged(tokens, accountId: accountId)
        XCTAssertFalse(written, "内容相同不应触发 Keychain 写入")
        XCTAssertEqual(ImportedCodexStore.loadTokens(accountId: accountId), tokens)
    }

    func testSaveTokensIfChangedWritesOnAccessChange() throws {
        let accountId = "test-access-\(UUID().uuidString)"
        defer { ImportedCodexStore.deleteTokens(accountId: accountId) }
        try ImportedCodexStore.saveTokens(makeTokens(), accountId: accountId)

        let mutated = makeTokens(access: "access-2")
        let written = try ImportedCodexStore.saveTokensIfChanged(mutated, accountId: accountId)
        XCTAssertTrue(written, "access token 变化应写入")
        XCTAssertEqual(ImportedCodexStore.loadTokens(accountId: accountId), mutated)
    }

    func testSaveTokensIfChangedWritesOnRefreshChange() throws {
        let accountId = "test-refresh-\(UUID().uuidString)"
        defer { ImportedCodexStore.deleteTokens(accountId: accountId) }
        try ImportedCodexStore.saveTokens(makeTokens(), accountId: accountId)

        let mutated = makeTokens(refresh: "refresh-2")
        let written = try ImportedCodexStore.saveTokensIfChanged(mutated, accountId: accountId)
        XCTAssertTrue(written, "refresh token 变化应写入")
        XCTAssertEqual(ImportedCodexStore.loadTokens(accountId: accountId), mutated)
    }

    func testSaveTokensIfChangedWritesOnIdChange() throws {
        let accountId = "test-id-\(UUID().uuidString)"
        defer { ImportedCodexStore.deleteTokens(accountId: accountId) }
        try ImportedCodexStore.saveTokens(makeTokens(), accountId: accountId)

        let mutated = makeTokens(id: "id-2")
        let written = try ImportedCodexStore.saveTokensIfChanged(mutated, accountId: accountId)
        XCTAssertTrue(written, "id token 变化应写入")
        XCTAssertEqual(ImportedCodexStore.loadTokens(accountId: accountId), mutated)
    }

    func testSaveTokensIfChangedHandlesMissingEntry() throws {
        let accountId = "test-missing-\(UUID().uuidString)"
        defer { ImportedCodexStore.deleteTokens(accountId: accountId) }
        // Keychain 里还没有条目：第一次同步应视为变化并创建。
        let written = try ImportedCodexStore.saveTokensIfChanged(makeTokens(), accountId: accountId)
        XCTAssertTrue(written)
        XCTAssertNotNil(ImportedCodexStore.loadTokens(accountId: accountId))
    }
}
