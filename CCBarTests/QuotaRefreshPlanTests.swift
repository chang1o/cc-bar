import XCTest
@testable import CCBar

/// 草案 §4.1 的 Provider 开关组合矩阵：计划构造与镜像判定。
final class QuotaRefreshPlanTests: XCTestCase {
    // MARK: - Plan 组合矩阵（纯函数，8 组合）

    func testAllProvidersEnabled() {
        let plan = QuotaRefreshPlan.make(
            showCodex: true, showClaude: true, showAntigravity: true, hasVisibleImported: true
        )
        XCTAssertTrue(plan.refreshCodex)
        XCTAssertTrue(plan.refreshClaude)
        XCTAssertTrue(plan.refreshAntigravity)
        XCTAssertTrue(plan.refreshImported)
        XCTAssertTrue(plan.canMirrorPrimary)
    }

    func testAllProvidersDisabled() {
        let plan = QuotaRefreshPlan.make(
            showCodex: false, showClaude: false, showAntigravity: false, hasVisibleImported: false
        )
        XCTAssertFalse(plan.refreshCodex)
        XCTAssertFalse(plan.refreshClaude)
        XCTAssertFalse(plan.refreshAntigravity)
        XCTAssertFalse(plan.refreshImported)
        XCTAssertFalse(plan.canMirrorPrimary)
    }

    func testCodexOnly() {
        let plan = QuotaRefreshPlan.make(
            showCodex: true, showClaude: false, showAntigravity: false, hasVisibleImported: false
        )
        XCTAssertTrue(plan.refreshCodex)
        XCTAssertFalse(plan.refreshClaude)
        XCTAssertFalse(plan.refreshAntigravity)
        XCTAssertTrue(plan.canMirrorPrimary)
    }

    func testClaudeOnly() {
        let plan = QuotaRefreshPlan.make(
            showCodex: false, showClaude: true, showAntigravity: false, hasVisibleImported: false
        )
        XCTAssertFalse(plan.refreshCodex)
        XCTAssertTrue(plan.refreshClaude)
        XCTAssertFalse(plan.refreshAntigravity)
        XCTAssertFalse(plan.canMirrorPrimary)
    }

    func testAntigravityOnly() {
        let plan = QuotaRefreshPlan.make(
            showCodex: false, showClaude: false, showAntigravity: true, hasVisibleImported: false
        )
        XCTAssertFalse(plan.refreshCodex)
        XCTAssertFalse(plan.refreshClaude)
        XCTAssertTrue(plan.refreshAntigravity)
        XCTAssertFalse(plan.canMirrorPrimary)
    }

    func testCodexPlusClaude() {
        let plan = QuotaRefreshPlan.make(
            showCodex: true, showClaude: true, showAntigravity: false, hasVisibleImported: false
        )
        XCTAssertTrue(plan.refreshCodex)
        XCTAssertTrue(plan.refreshClaude)
        XCTAssertFalse(plan.refreshAntigravity)
        XCTAssertTrue(plan.canMirrorPrimary)
    }

    func testClaudePlusAntigravity() {
        let plan = QuotaRefreshPlan.make(
            showCodex: false, showClaude: true, showAntigravity: true, hasVisibleImported: false
        )
        XCTAssertFalse(plan.refreshCodex)
        XCTAssertTrue(plan.refreshClaude)
        XCTAssertTrue(plan.refreshAntigravity)
        XCTAssertFalse(plan.canMirrorPrimary)
    }

    func testCodexPlusAntigravity() {
        let plan = QuotaRefreshPlan.make(
            showCodex: true, showClaude: false, showAntigravity: true, hasVisibleImported: false
        )
        XCTAssertTrue(plan.refreshCodex)
        XCTAssertFalse(plan.refreshClaude)
        XCTAssertTrue(plan.refreshAntigravity)
        XCTAssertTrue(plan.canMirrorPrimary)
    }

    /// hasVisibleImported 只影响导入调度标志，不影响主 Provider 与镜像能力。
    func testVisibleImportedIndependentFromProviders() {
        let plan = QuotaRefreshPlan.make(
            showCodex: false, showClaude: false, showAntigravity: false, hasVisibleImported: true
        )
        XCTAssertFalse(plan.refreshCodex)
        XCTAssertFalse(plan.canMirrorPrimary)
        XCTAssertTrue(plan.refreshImported)
    }

    // MARK: - 镜像判定矩阵（AppState 展示层）

    private var appState: AppState!
    private var savedShowCodex: Bool!

    override func setUp() {
        super.setUp()
        savedShowCodex = SettingsStore.shared.showCodex
        appState = AppState()
    }

    override func tearDown() {
        SettingsStore.shared.showCodex = savedShowCodex
        appState = nil
        super.tearDown()
    }

    private func makeAccount(id: String) -> ImportedCodexAccount {
        ImportedCodexAccount(
            id: id,
            alias: "",
            email: nil,
            planType: nil,
            visibleInPopover: true,
            addedAt: Date()
        )
    }

    private func makePrimary(accountId: String, userId: String?) -> CodexAccount {
        CodexAccount(
            email: nil,
            planType: nil,
            accountId: accountId,
            chatgptUserId: userId,
            lastRefresh: nil,
            expiredGuess: false,
            rawClaimKeys: [],
            accessToken: nil,
            refreshToken: nil,
            idToken: nil
        )
    }

    @MainActor
    func testMirrorPrimaryOnSameIdentity() {
        appState.codexAccount = makePrimary(accountId: "acc-1", userId: "user-1")
        let imported = makeAccount(id: "acc-1:user-1")
        SettingsStore.shared.showCodex = true
        XCTAssertTrue(appState.importedCodexAccountMirrorsPrimary(imported))
    }

    /// 主 Codex 关闭时，即使内存还留有旧身份，导入账号也不能镜像旧快照（草案 2.1）。
    @MainActor
    func testMirrorDisabledWhenPrimaryProviderOff() {
        appState.codexAccount = makePrimary(accountId: "acc-1", userId: "user-1")
        let imported = makeAccount(id: "acc-1:user-1")
        SettingsStore.shared.showCodex = false
        XCTAssertFalse(appState.importedCodexAccountMirrorsPrimary(imported))
    }

    @MainActor
    func testNoMirrorOnDifferentIdentity() {
        appState.codexAccount = makePrimary(accountId: "acc-1", userId: "user-1")
        let imported = makeAccount(id: "acc-2:user-2")
        SettingsStore.shared.showCodex = true
        XCTAssertFalse(appState.importedCodexAccountMirrorsPrimary(imported))
    }

    @MainActor
    func testNoMirrorWhenPrimaryMissing() {
        appState.codexAccount = nil
        let imported = makeAccount(id: "acc-1:user-1")
        SettingsStore.shared.showCodex = true
        XCTAssertFalse(appState.importedCodexAccountMirrorsPrimary(imported))
    }

    /// 老数据：导入账号无 user_id（单段 id），主账号有 user_id → 退化为 accountId 相同即镜像。
    @MainActor
    func testMirrorDegradesToAccountIdWhenImportedUserIdMissing() {
        appState.codexAccount = makePrimary(accountId: "acc-1", userId: "user-1")
        let imported = makeAccount(id: "acc-1")
        SettingsStore.shared.showCodex = true
        XCTAssertTrue(appState.importedCodexAccountMirrorsPrimary(imported))
    }
}
