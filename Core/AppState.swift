import AppKit
import Foundation
import Observation

@Observable
@MainActor
final class AppState {
    var codexAccount: CodexAccount?
    var claudeAccount: ClaudeAccount?
    var codexError: String?
    var claudeError: String?

    // MARK: 导入的 Codex 副账号
    //
    // 用户手动粘贴 auth.json 添加的"其他账号"。与默认账号(`~/.codex/auth.json`)解耦,
    // 允许重复出现,token 走 Keychain (见 ImportedCodexStore)。
    // - `importedCodexAccounts` 元数据列表,保持添加顺序。
    // - `importedCodexQuotas / Sources / Errors / RefreshStates` 按 account.id 索引,
    //   只在该账号 `visibleInPopover` 为 true 时才刷新与展示。
    var importedCodexAccounts: [ImportedCodexAccount] = []
    var importedCodexQuotas: [String: QuotaSnapshot] = [:]
    var importedCodexSources: [String: QuotaSnapshotSource] = [:]
    var importedCodexErrors: [String: String] = [:]
    var importedCodexRefreshStates: [String: QuotaRefreshState] = [:]

    var ccpmCodexProfiles: [CCPMCodexProfile] = []
    var ccpmCodexAccounts: [String: CodexAccount] = [:]
    var ccpmCodexQuotas: [String: QuotaSnapshot] = [:]
    var ccpmCodexSources: [String: QuotaSnapshotSource] = [:]
    var ccpmCodexErrors: [String: String] = [:]
    var ccpmCodexRefreshStates: [String: QuotaRefreshState] = [:]

    var ccpmClaudeProfiles: [CCPMClaudeProfile] = []
    var ccpmClaudeAccounts: [String: ClaudeAccount] = [:]
    var ccpmClaudeQuotas: [String: QuotaSnapshot] = [:]
    var ccpmClaudeSources: [String: QuotaSnapshotSource] = [:]
    var ccpmClaudeErrors: [String: String] = [:]
    var ccpmClaudeRefreshStates: [String: QuotaRefreshState] = [:]

    /// 主窗口当前 tab,允许 ⌘1 / ⌘, 等命令从外部驱动切换
    var mainTab: MainTab = .stats

    /// 首次启动时由 bootstrap 设为 true,触发 Onboarding 窗口
    var shouldShowOnboarding: Bool = false

    var codexQuota: QuotaSnapshot?
    var claudeQuota: QuotaSnapshot?
    var codexQuotaError: String?
    var claudeQuotaError: String?
    var codexQuotaSource: QuotaSnapshotSource?
    var claudeQuotaSource: QuotaSnapshotSource?
    var codexRefreshState = QuotaRefreshState()
    var claudeRefreshState = QuotaRefreshState()
    var quotaHistory = QuotaHistoryPayload()

    var codexTodayCost: Decimal?
    var claudeTodayCost: Decimal?

    /// OpenAI / Anthropic statuspage.io 最新快照,失败时保留上一份。
    var codexServiceStatus: ServiceStatus?
    var claudeServiceStatus: ServiceStatus?

    let usageService = UsageService()
    private let scheduler = Scheduler()
    private var didBootstrap = false
    private var quotaCache = QuotaCachePayload()
    private var claudeFallbackBackoffUntil: Date?

    /// `refreshNow()` 的去重锁。同一时刻只允许一个真正在跑的整体刷新;
    /// 期间额外的 `refreshNow()` 调用立即返回(no-op),不再排队。
    /// UI 的"刷新按钮"依然每点必转图标,只是不会真的发起重复请求。
    private var refreshInFlight: Task<Void, Never>?

    /// `ClaudeDelegatedRefresh` 完成成功时的通知订阅。
    /// 保留引用以便释放时取消(目前 AppState 生命周期 = App 生命周期,实际不会释放)。
    private var delegatedRefreshObserver: NSObjectProtocol?

    private let minSuccessInterval: TimeInterval = 60
    private let rateLimitBackoff: TimeInterval = 10 * 60

    func bootstrap() async {
        guard !didBootstrap else { return }
        didBootstrap = true

        subscribeToDelegatedRefreshSuccess()
        loadQuotaCache()
        loadQuotaHistory()
        reloadImportedCodexAccounts()
        reloadCCPMCodexProfiles()
        reloadCCPMClaudeProfiles()
        usageService.bootstrap(appState: self)
        await loadCodex()
        maybeShowKeychainPrompt()
        await loadClaude()
        logCredentialSummary()

        if !SettingsStore.shared.didCompleteOnboarding {
            shouldShowOnboarding = true
        }

        let settings = SettingsStore.shared
        scheduler.start(
            appState: self,
            quotaInterval: settings.quotaInterval.seconds,
            usageInterval: settings.usageInterval.seconds
        )
        // 启动后台触发一次 JSONL 扫描，让今日 cost 立刻更新（不阻塞 bootstrap）
        Task { await usageService.scanNow() }
        // 启动后异步拉一次服务状态;后续由 Scheduler 5 分钟刷新一次
        Task { await refreshServiceStatus() }
    }

    /// 设置变更后，把刷新间隔同步到 Scheduler
    func applySettingsChange() {
        let settings = SettingsStore.shared
        scheduler.setQuotaInterval(settings.quotaInterval.seconds)
        scheduler.setUsageInterval(settings.usageInterval.seconds)
    }

    func refreshNow() async {
        // 去重:已有刷新在跑就直接返回,避免用户连点导致多份并发请求。
        // UI 端不依赖这里的 await 时长,按钮立刻就响应了。
        if refreshInFlight != nil { return }
        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await self.refreshQuotas(reason: .userInitiated)
            await self.usageService.scanNow()
            await self.refreshServiceStatus()
        }
        refreshInFlight = task
        await task.value
        refreshInFlight = nil
    }

    /// 订阅 `ClaudeDelegatedRefresh` 后台委托刷新成功的通知。
    /// 一旦 claude CLI 在后台帮我们刷新了 token 并写回了 keychain,
    /// 这里会自动触发一次完整刷新,UI 拿到新数据,用户全程无感。
    private func subscribeToDelegatedRefreshSuccess() {
        delegatedRefreshObserver = NotificationCenter.default.addObserver(
            forName: .claudeDelegatedRefreshDidSucceed,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // queue: .main 保证回调线程,再 Task 进 MainActor 做异步刷新。
            Task { @MainActor [weak self] in
                guard let self else { return }
                // 用 .periodic 而不是 .userInitiated,避免被当作"用户操作"
                // 影响速率限制 / 退避策略。
                await self.refreshQuotas(reason: .periodic)
            }
        }
    }

    /// 每次刷新(手动 / Scheduler 定时)都先重读本地凭据,以便用户在外部
    /// (如 cc-switch)切换账号后 ccbar 能感知到。loadCodex / loadClaude
    /// 内部会比较 accountId / email,若身份变化则清掉旧的额度缓存,避免
    /// 出现"新账号 + 旧额度"的错配。
    func refreshQuotas(reason: QuotaRefreshReason = .periodic) async {
        await loadCodex()
        await loadClaude()
        reloadCCPMCodexProfiles()
        reloadCCPMClaudeProfiles()
        let settings = SettingsStore.shared
        if settings.showCodex {
            await loadCodexQuota(reason: reason)
            await loadAllImportedCodexQuotas(reason: reason)
            await loadAllCCPMCodexProfileQuotas(reason: reason)
        }
        if settings.showClaude {
            await loadClaudeQuota(reason: reason)
            await loadAllCCPMClaudeProfileQuotas(reason: reason)
        }
        logQuotaSummary()
    }

    /// 拉取 OpenAI / Anthropic statuspage 状态。失败保留旧快照,不清空。
    /// 两个请求并发,任意一个失败不影响另一个。
    func refreshServiceStatus() async {
        let settings = SettingsStore.shared
        async let codex = Self.fetchServiceStatusIfEnabled(
            settings.showCodex,
            url: ServiceStatusClient.openAIStatusURL,
            tag: "openai"
        )
        async let claude = Self.fetchServiceStatusIfEnabled(
            settings.showClaude,
            url: ServiceStatusClient.anthropicStatusURL,
            tag: "anthropic"
        )
        let codexResult = await codex
        let claudeResult = await claude
        if let codexResult { codexServiceStatus = codexResult }
        if let claudeResult { claudeServiceStatus = claudeResult }
    }

    private static func fetchServiceStatusIfEnabled(_ enabled: Bool, url: URL, tag: String) async -> ServiceStatus? {
        guard enabled else { return nil }
        return await fetchServiceStatus(url: url, tag: tag)
    }

    private static func fetchServiceStatus(url: URL, tag: String) async -> ServiceStatus? {
        do {
            return try await ServiceStatusClient.fetch(from: url)
        } catch {
            print("[service-status] \(tag) fetch failed: \(error)")
            return nil
        }
    }

    func quotaStatusLine(for app: QuotaApp) -> String? {
        let snapshot: QuotaSnapshot?
        let source: QuotaSnapshotSource?
        let error: String?
        let state: QuotaRefreshState
        switch app {
        case .codex:
            snapshot = codexQuota
            source = codexQuotaSource
            error = codexQuotaError
            state = codexRefreshState
        case .claude:
            snapshot = claudeQuota
            source = claudeQuotaSource
            error = claudeQuotaError
            state = claudeRefreshState
        }

        var parts: [String] = []
        if let snapshot, !format(snapshot).isEmpty {
            parts.append(format(snapshot))
        }
        if let source {
            parts.append(source.displayName)
        }
        if let lastSuccessAt = state.lastSuccessAt {
            parts.append("更新 \(relativeAge(from: lastSuccessAt))前")
        }
        if let backoffUntil = state.backoffUntil, backoffUntil > Date() {
            parts.append("限流退避 \(relativeAge(until: backoffUntil))")
        }
        if let error, !error.isEmpty {
            parts.append("错误: \(shortError(error))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func loadQuotaCache() {
        quotaCache = QuotaCache.load()
        if let record = quotaCache.codex {
            codexQuota = record.snapshot
            codexQuotaSource = .cache
            codexRefreshState.lastSuccessAt = record.updatedAt
            codexRefreshState.source = .cache
        }
        if let record = quotaCache.claude {
            claudeQuota = record.snapshot
            claudeQuotaSource = .cache
            claudeRefreshState.lastSuccessAt = record.updatedAt
            claudeRefreshState.source = .cache
        }
        for (id, record) in quotaCache.importedCodex ?? [:] {
            importedCodexQuotas[id] = record.snapshot
            importedCodexSources[id] = .cache
            var state = QuotaRefreshState()
            state.lastSuccessAt = record.updatedAt
            state.source = .cache
            importedCodexRefreshStates[id] = state
        }
        for (id, record) in quotaCache.ccpmCodex ?? [:] {
            ccpmCodexQuotas[id] = record.snapshot
            ccpmCodexSources[id] = .cache
            var state = QuotaRefreshState()
            state.lastSuccessAt = record.updatedAt
            state.source = .cache
            ccpmCodexRefreshStates[id] = state
        }
        for (id, record) in quotaCache.ccpmClaude ?? [:] {
            ccpmClaudeQuotas[id] = record.snapshot
            ccpmClaudeSources[id] = .cache
            var state = QuotaRefreshState()
            state.lastSuccessAt = record.updatedAt
            state.source = .cache
            ccpmClaudeRefreshStates[id] = state
        }
    }

    private func loadQuotaHistory() {
        quotaHistory = QuotaHistoryStore.load()
        saveQuotaHistory()
    }

    // MARK: - Imported Codex accounts

    /// 从磁盘读取元数据列表,移除内存中已经不存在的账号的运行时状态。
    /// 设置页增删账号后由调用方触发。
    func reloadImportedCodexAccounts() {
        importedCodexAccounts = ImportedCodexStore.loadAll()
        let alive = Set(importedCodexAccounts.map(\.id))
        importedCodexQuotas = importedCodexQuotas.filter { alive.contains($0.key) }
        importedCodexSources = importedCodexSources.filter { alive.contains($0.key) }
        importedCodexErrors = importedCodexErrors.filter { alive.contains($0.key) }
        importedCodexRefreshStates = importedCodexRefreshStates.filter { alive.contains($0.key) }
        var importedCache = quotaCache.importedCodex ?? [:]
        importedCache = importedCache.filter { alive.contains($0.key) }
        quotaCache.importedCodex = importedCache.isEmpty ? nil : importedCache
        saveQuotaCache()
    }

    /// 增 / 改:同 account_id 静默覆盖 token,元数据按入参更新;新增时落到列表末尾。
    func upsertImportedCodexAccount(
        from parsed: ImportedCodexPaste.Parsed,
        alias: String,
        visibleInPopover: Bool
    ) throws {
        let tokens = ImportedCodexTokens(
            accessToken: parsed.accessToken,
            refreshToken: parsed.refreshToken,
            idToken: parsed.idToken
        )
        try ImportedCodexStore.saveTokens(tokens, accountId: parsed.id)

        var list = ImportedCodexStore.loadAll()
        if let idx = list.firstIndex(where: { $0.id == parsed.id }) {
            var existing = list[idx]
            existing.alias = alias
            existing.email = parsed.email ?? existing.email
            existing.planType = parsed.planType ?? existing.planType
            existing.visibleInPopover = visibleInPopover
            list[idx] = existing
        } else {
            list.append(ImportedCodexAccount(
                id: parsed.id,
                alias: alias,
                email: parsed.email,
                planType: parsed.planType,
                visibleInPopover: visibleInPopover,
                addedAt: Date()
            ))
        }
        try ImportedCodexStore.saveAll(list)
        reloadImportedCodexAccounts()
    }

    /// 仅更新元数据(别名、颜色、显示开关),不动 token。
    func updateImportedCodexMetadata(id: String, mutate: (inout ImportedCodexAccount) -> Void) {
        var list = ImportedCodexStore.loadAll()
        guard let idx = list.firstIndex(where: { $0.id == id }) else { return }
        mutate(&list[idx])
        do { try ImportedCodexStore.saveAll(list) } catch {
            print("[imported-codex] save metadata failed: \(error)")
            return
        }
        reloadImportedCodexAccounts()
    }

    /// 按给定 id 顺序重排导入账号(忽略不存在的 id,缺失的追加到末尾)。
    func reorderImportedCodexAccounts(orderedIds: [String]) {
        let list = ImportedCodexStore.loadAll()
        let byId = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
        var seen = Set<String>()
        var reordered: [ImportedCodexAccount] = []
        for id in orderedIds {
            guard let acc = byId[id], !seen.contains(id) else { continue }
            reordered.append(acc)
            seen.insert(id)
        }
        for acc in list where !seen.contains(acc.id) {
            reordered.append(acc)
        }
        guard reordered.map(\.id) != list.map(\.id) else { return }
        do { try ImportedCodexStore.saveAll(reordered) } catch {
            print("[imported-codex] reorder failed: \(error)")
            return
        }
        reloadImportedCodexAccounts()
    }

    /// 删除:同步清 Keychain、元数据、运行时状态与缓存。
    func removeImportedCodexAccount(id: String) {
        ImportedCodexStore.deleteTokens(accountId: id)
        let list = ImportedCodexStore.loadAll().filter { $0.id != id }
        do { try ImportedCodexStore.saveAll(list) } catch {
            print("[imported-codex] delete failed: \(error)")
        }
        reloadImportedCodexAccounts()
    }

    func reloadCCPMCodexProfiles() {
        let previous = Dictionary(uniqueKeysWithValues: ccpmCodexProfiles.map { ($0.id, $0) })
        let profiles = CCPMCodexProfileStore.loadProfiles()
        let changed = Set(profiles.compactMap { profile -> String? in
            guard let old = previous[profile.id],
                  codexProfileIdentityChanged(previous: old, next: profile)
            else { return nil }
            return profile.id
        })
        ccpmCodexProfiles = profiles

        let alive = Set(profiles.map(\.id)).subtracting(changed)
        ccpmCodexAccounts = ccpmCodexAccounts.filter { alive.contains($0.key) }
        ccpmCodexQuotas = ccpmCodexQuotas.filter { alive.contains($0.key) }
        ccpmCodexSources = ccpmCodexSources.filter { alive.contains($0.key) }
        ccpmCodexErrors = ccpmCodexErrors.filter { alive.contains($0.key) }
        ccpmCodexRefreshStates = ccpmCodexRefreshStates.filter { alive.contains($0.key) }
        var cache = quotaCache.ccpmCodex ?? [:]
        cache = cache.filter { alive.contains($0.key) }
        quotaCache.ccpmCodex = cache.isEmpty ? nil : cache
        saveQuotaCache()
    }

    var ccpmCodexProfilesForMonitoring: [CCPMCodexProfile] {
        ccpmCodexProfiles
            .filter { $0.authMethod == .oauth }
            .sorted { lhs, rhs in
                switch (lhs.lastUsed, rhs.lastUsed) {
                case let (left?, right?) where left != right:
                    return left > right
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                default:
                    return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                }
            }
    }

    var hasCCPMCodexProfiles: Bool {
        !ccpmCodexProfilesForMonitoring.isEmpty
    }

    func ccpmCodexQuota(for profile: CCPMCodexProfile) -> QuotaSnapshot? {
        if ccpmCodexProfileMirrorsPrimary(profile) { return codexQuota }
        if let imported = importedCodexAccount(matching: profile) {
            return importedCodexQuota(for: imported)
        }
        return ccpmCodexQuotas[profile.id]
    }

    func ccpmCodexError(for profile: CCPMCodexProfile) -> String? {
        if ccpmCodexProfileMirrorsPrimary(profile) { return codexQuotaError }
        if let imported = importedCodexAccount(matching: profile) {
            return importedCodexError(for: imported)
        }
        return ccpmCodexErrors[profile.id]
    }

    func ccpmCodexRefreshState(for profile: CCPMCodexProfile) -> QuotaRefreshState {
        if ccpmCodexProfileMirrorsPrimary(profile) { return codexRefreshState }
        if let imported = importedCodexAccount(matching: profile) {
            return importedCodexRefreshState(for: imported)
        }
        return ccpmCodexRefreshStates[profile.id] ?? QuotaRefreshState()
    }

    func reloadCCPMClaudeProfiles() {
        ccpmClaudeProfiles = CCPMClaudeProfileStore.loadProfiles()
        let alive = Set(ccpmClaudeProfiles.map(\.id))
        ccpmClaudeAccounts = ccpmClaudeAccounts.filter { alive.contains($0.key) }
        ccpmClaudeQuotas = ccpmClaudeQuotas.filter { alive.contains($0.key) }
        ccpmClaudeSources = ccpmClaudeSources.filter { alive.contains($0.key) }
        ccpmClaudeErrors = ccpmClaudeErrors.filter { alive.contains($0.key) }
        ccpmClaudeRefreshStates = ccpmClaudeRefreshStates.filter { alive.contains($0.key) }
        var cache = quotaCache.ccpmClaude ?? [:]
        cache = cache.filter { alive.contains($0.key) }
        quotaCache.ccpmClaude = cache.isEmpty ? nil : cache
        saveQuotaCache()
    }

    var ccpmClaudeProfilesForMonitoring: [CCPMClaudeProfile] {
        ccpmClaudeProfiles
            .filter { $0.authMethod == .oauth }
            .sorted { lhs, rhs in
                if lhs.isDefault != rhs.isDefault { return lhs.isDefault }
                switch (lhs.lastUsed, rhs.lastUsed) {
                case let (l?, r?) where l != r:
                    return l > r
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                default:
                    return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                }
            }
    }

    var hasCCPMClaudeProfiles: Bool {
        !ccpmClaudeProfilesForMonitoring.isEmpty
    }

    func claudeMonitorQuota() -> QuotaSnapshot? {
        if let aggregate = aggregateClaudeMonitorQuota() {
            return aggregate
        }
        return nil
    }

    func claudeMonitorError() -> String? {
        if let error = claudeQuotaError, !error.isEmpty {
            return error
        }
        for profile in ccpmClaudeProfilesForMonitoring {
            if let error = ccpmClaudeErrors[profile.id], !error.isEmpty {
                return error
            }
        }
        return nil
    }

    func ccpmClaudeQuota(for profile: CCPMClaudeProfile) -> QuotaSnapshot? {
        ccpmClaudeQuotas[profile.id]
    }

    func ccpmClaudeError(for profile: CCPMClaudeProfile) -> String? {
        ccpmClaudeErrors[profile.id]
    }

    func ccpmClaudeRefreshState(for profile: CCPMClaudeProfile) -> QuotaRefreshState {
        ccpmClaudeRefreshStates[profile.id] ?? QuotaRefreshState()
    }

    private func aggregateClaudeMonitorQuota() -> QuotaSnapshot? {
        var snapshots: [QuotaSnapshot] = []
        if let claudeQuota {
            snapshots.append(claudeQuota)
        }
        snapshots.append(contentsOf: ccpmClaudeProfilesForMonitoring.compactMap { ccpmClaudeQuotas[$0.id] })
        guard !snapshots.isEmpty else { return nil }

        return QuotaSnapshot(
            app: .claude,
            fiveHour: mostConstrainedWindow(snapshots.map(\.fiveHour)),
            weekly: mostConstrainedWindow(snapshots.map(\.weekly)),
            weeklyOpus: mostConstrainedWindow(snapshots.map(\.weeklyOpus)),
            weeklySonnet: mostConstrainedWindow(snapshots.map(\.weeklySonnet)),
            planType: nil,
            fetchedAt: snapshots.map(\.fetchedAt).max() ?? Date()
        )
    }

    private func mostConstrainedWindow(_ windows: [QuotaWindow?]) -> QuotaWindow? {
        windows
            .compactMap { $0 }
            .min { lhs, rhs in
                lhs.remainingPercent < rhs.remainingPercent
            }
    }

    func importedCodexQuota(for account: ImportedCodexAccount) -> QuotaSnapshot? {
        if importedCodexAccountMirrorsPrimary(account) { return codexQuota }
        return importedCodexQuotas[account.id]
    }

    func importedCodexError(for account: ImportedCodexAccount) -> String? {
        if importedCodexAccountMirrorsPrimary(account) { return codexQuotaError }
        return importedCodexErrors[account.id]
    }

    func importedCodexRefreshState(for account: ImportedCodexAccount) -> QuotaRefreshState {
        if importedCodexAccountMirrorsPrimary(account) { return codexRefreshState }
        return importedCodexRefreshStates[account.id] ?? QuotaRefreshState()
    }

    /// 对所有 `visibleInPopover` 为 true 的导入账号并发拉一遍配额,并发上限 3。
    private func loadAllImportedCodexQuotas(reason: QuotaRefreshReason) async {
        guard SettingsStore.shared.showCodex else { return }
        let visible = importedCodexAccounts.filter(\.visibleInPopover)
        guard !visible.isEmpty else { return }
        let maxConcurrent = 3
        var index = 0
        while index < visible.count {
            let batch = Array(visible[index..<min(index + maxConcurrent, visible.count)])
            await withTaskGroup(of: Void.self) { group in
                for account in batch {
                    group.addTask { [weak self] in
                        guard let self else { return }
                        await self.loadImportedCodexQuota(account: account, reason: reason)
                    }
                }
            }
            index += maxConcurrent
        }
    }

    private func loadImportedCodexQuota(account: ImportedCodexAccount, reason: QuotaRefreshReason) async {
        if importedCodexAccountMirrorsPrimary(account) {
            mirrorPrimaryCodexQuota(toImportedId: account.id)
            syncPrimaryCodexTokensToImported(id: account.id)
            return
        }

        guard beginImportedCodexRefresh(id: account.id, reason: reason) else { return }
        defer { importedCodexRefreshStates[account.id]?.inFlight = false }

        guard let tokens = ImportedCodexStore.loadTokens(accountId: account.id) else {
            markImportedCodexFailure(id: account.id, message: "missing tokens in keychain")
            return
        }
        let refreshed = await CodexTokenRefresher.ensureFreshAccessToken(
            currentAccessToken: tokens.accessToken,
            refreshToken: tokens.refreshToken,
            writeBack: .importedAccount(id: account.id)
        )
        let activeToken: String
        switch refreshed {
        case .success(let t):
            activeToken = t
        case .failure(let err):
            markImportedCodexFailure(id: account.id, message: err.description, error: err)
            return
        }
        let result = await CodexQuotaClient.fetch(accessToken: activeToken, accountId: account.chatgptAccountId)
        switch result {
        case .success(let snapshot):
            storeImportedCodex(id: account.id, snapshot: snapshot, source: .api)
        case .failure(let err):
            markImportedCodexFailure(id: account.id, message: err.description, error: err)
        }
    }

    private func importedCodexAccountMirrorsPrimary(_ account: ImportedCodexAccount) -> Bool {
        guard let primary = codexAccount else { return false }
        return codexIdentityMatches(
            accountId: account.chatgptAccountId,
            userId: importedCodexUserId(from: account),
            otherAccountId: primary.accountId,
            otherUserId: primary.chatgptUserId
        )
    }

    private func importedCodexUserId(from account: ImportedCodexAccount) -> String? {
        guard let colon = account.id.firstIndex(of: ":") else { return nil }
        let tail = String(account.id[account.id.index(after: colon)...])
        return nonEmpty(tail)
    }

    private func mirrorPrimaryCodexQuota(toImportedId id: String) {
        importedCodexQuotas[id] = codexQuota
        importedCodexSources[id] = codexQuotaSource
        importedCodexErrors[id] = codexQuotaError
        importedCodexRefreshStates[id] = codexRefreshState

        if let snapshot = codexQuota, codexQuotaSource == .api {
            recordImportedCodexQuotaHistory(
                id: id,
                snapshot: snapshot,
                sampledAt: codexRefreshState.lastSuccessAt ?? Date()
            )
        }

        var cache = quotaCache.importedCodex ?? [:]
        if cache.removeValue(forKey: id) != nil {
            quotaCache.importedCodex = cache.isEmpty ? nil : cache
            saveQuotaCache()
        }
    }

    private func syncPrimaryCodexTokensToImported(id: String) {
        guard let account = codexAccount,
              let accessToken = nonEmpty(account.accessToken)
        else { return }
        let tokens = ImportedCodexTokens(
            accessToken: accessToken,
            refreshToken: nonEmpty(account.refreshToken),
            idToken: nonEmpty(account.idToken)
        )
        do {
            try ImportedCodexStore.saveTokens(tokens, accountId: id)
        } catch {
            print("[imported-codex] sync primary tokens failed: \(error)")
        }
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    private func codexProfileIdentityChanged(
        previous: CCPMCodexProfile,
        next: CCPMCodexProfile
    ) -> Bool {
        guard let previousAccountId = nonEmpty(previous.accountId),
              let nextAccountId = nonEmpty(next.accountId)
        else { return false }
        if previousAccountId != nextAccountId { return true }
        if let previousUserId = nonEmpty(previous.chatgptUserId),
           let nextUserId = nonEmpty(next.chatgptUserId) {
            return previousUserId != nextUserId
        }
        return false
    }

    private func codexIdentityMatches(
        accountId: String?,
        userId: String?,
        otherAccountId: String?,
        otherUserId: String?
    ) -> Bool {
        guard let accountId = nonEmpty(accountId),
              let otherAccountId = nonEmpty(otherAccountId),
              accountId == otherAccountId
        else { return false }

        if let userId = nonEmpty(userId),
           let otherUserId = nonEmpty(otherUserId) {
            return userId == otherUserId
        }
        return true
    }

    private func ccpmCodexProfileMirrorsPrimary(_ profile: CCPMCodexProfile) -> Bool {
        guard let primary = codexAccount else { return false }
        return codexIdentityMatches(
            accountId: profile.accountId,
            userId: profile.chatgptUserId,
            otherAccountId: primary.accountId,
            otherUserId: primary.chatgptUserId
        )
    }

    private func importedCodexAccount(matching profile: CCPMCodexProfile) -> ImportedCodexAccount? {
        importedCodexAccounts
            .filter(\.visibleInPopover)
            .first { account in
                codexIdentityMatches(
                    accountId: profile.accountId,
                    userId: profile.chatgptUserId,
                    otherAccountId: account.chatgptAccountId,
                    otherUserId: importedCodexUserId(from: account)
                )
            }
    }

    private func beginImportedCodexRefresh(id: String, reason: QuotaRefreshReason) -> Bool {
        let now = Date()
        var state = importedCodexRefreshStates[id] ?? QuotaRefreshState()
        guard !state.inFlight else { return false }
        if let backoffUntil = state.backoffUntil, backoffUntil > now {
            state.lastError = backoffMessage(until: backoffUntil)
            importedCodexRefreshStates[id] = state
            importedCodexErrors[id] = state.lastError
            return false
        }
        if reason == .periodic,
           let lastSuccessAt = state.lastSuccessAt,
           now.timeIntervalSince(lastSuccessAt) < minSuccessInterval
        {
            return false
        }
        state.inFlight = true
        state.lastAttemptAt = now
        importedCodexRefreshStates[id] = state
        return true
    }

    private func storeImportedCodex(id: String, snapshot: QuotaSnapshot, source: QuotaSnapshotSource) {
        let updatedAt = Date()
        importedCodexQuotas[id] = snapshot
        importedCodexSources[id] = source
        importedCodexErrors[id] = nil
        var state = importedCodexRefreshStates[id] ?? QuotaRefreshState()
        state.lastSuccessAt = updatedAt
        state.lastError = nil
        state.backoffUntil = nil
        state.source = source
        importedCodexRefreshStates[id] = state

        var cache = quotaCache.importedCodex ?? [:]
        cache[id] = QuotaCacheRecord(snapshot: snapshot, source: source, updatedAt: updatedAt)
        quotaCache.importedCodex = cache
        saveQuotaCache()
        recordImportedCodexQuotaHistory(id: id, snapshot: snapshot, sampledAt: updatedAt)
    }

    private func markImportedCodexFailure(id: String, message: String, error: QuotaError? = nil) {
        importedCodexErrors[id] = message
        var state = importedCodexRefreshStates[id] ?? QuotaRefreshState()
        state.lastError = message
        if error?.isRateLimited == true {
            state.backoffUntil = Date().addingTimeInterval(rateLimitBackoff)
        }
        importedCodexRefreshStates[id] = state
    }

    private func loadAllCCPMCodexProfileQuotas(reason: QuotaRefreshReason) async {
        guard SettingsStore.shared.showCodex else { return }
        let profiles = ccpmCodexProfilesForMonitoring
        guard !profiles.isEmpty else { return }
        let maxConcurrent = 3
        var index = 0
        while index < profiles.count {
            let batch = Array(profiles[index..<min(index + maxConcurrent, profiles.count)])
            await withTaskGroup(of: Void.self) { group in
                for profile in batch {
                    group.addTask { [weak self] in
                        guard let self else { return }
                        await self.loadCCPMCodexProfileQuota(profile: profile, reason: reason)
                    }
                }
            }
            index += maxConcurrent
        }
    }

    private func loadCCPMCodexProfileQuota(profile: CCPMCodexProfile, reason: QuotaRefreshReason) async {
        if ccpmCodexProfileMirrorsPrimary(profile) {
            mirrorPrimaryCodexQuota(toCCPMProfileId: profile.id)
            return
        }
        if let imported = importedCodexAccount(matching: profile) {
            mirrorImportedCodexQuota(imported, toCCPMProfileId: profile.id)
            return
        }

        guard beginCCPMCodexRefresh(id: profile.id, reason: reason) else { return }
        defer { ccpmCodexRefreshStates[profile.id]?.inFlight = false }

        var account: CodexAccount
        do {
            account = try await Task.detached(priority: .utility) {
                try CCPMCodexProfileStore.loadAccount(profile: profile)
            }.value
        } catch {
            markCCPMCodexFailure(id: profile.id, message: "\(error)")
            return
        }

        ccpmCodexAccounts[profile.id] = account
        guard let accessToken = nonEmpty(account.accessToken) else {
            markCCPMCodexFailure(id: profile.id, message: QuotaError.missingToken.description)
            return
        }

        let refreshed = await CodexTokenRefresher.ensureFreshTokens(
            currentAccessToken: accessToken,
            refreshToken: account.refreshToken,
            idToken: account.idToken,
            writeBack: .codexAuthJSONAt(path: profile.authFilePath)
        )
        let activeToken: String
        switch refreshed {
        case .success(let tokens):
            activeToken = tokens.accessToken
            account.accessToken = tokens.accessToken
            account.refreshToken = nonEmpty(tokens.refreshToken)
            account.idToken = tokens.idToken
            account.expiredGuess = false
            ccpmCodexAccounts[profile.id] = account
        case .failure(let error):
            markCCPMCodexFailure(id: profile.id, message: error.description, error: error)
            return
        }

        let result = await CodexQuotaClient.fetch(
            accessToken: activeToken,
            accountId: account.accountId
        )
        switch result {
        case .success(let snapshot):
            storeCCPMCodex(id: profile.id, snapshot: snapshot, source: .api)
        case .failure(let error):
            markCCPMCodexFailure(id: profile.id, message: error.description, error: error)
        }
    }

    private func mirrorPrimaryCodexQuota(toCCPMProfileId id: String) {
        ccpmCodexQuotas[id] = codexQuota
        ccpmCodexSources[id] = codexQuotaSource
        ccpmCodexErrors[id] = codexQuotaError
        ccpmCodexRefreshStates[id] = codexRefreshState
        if let snapshot = codexQuota, codexQuotaSource == .api {
            recordCCPMCodexProfileQuotaHistory(
                id: id,
                snapshot: snapshot,
                sampledAt: codexRefreshState.lastSuccessAt ?? Date()
            )
        }
        removeCCPMCodexCache(id: id)
    }

    private func mirrorImportedCodexQuota(
        _ account: ImportedCodexAccount,
        toCCPMProfileId id: String
    ) {
        ccpmCodexQuotas[id] = importedCodexQuota(for: account)
        ccpmCodexSources[id] = importedCodexSources[account.id]
        ccpmCodexErrors[id] = importedCodexError(for: account)
        ccpmCodexRefreshStates[id] = importedCodexRefreshState(for: account)
        if let snapshot = importedCodexQuota(for: account),
           importedCodexSources[account.id] == .api {
            recordCCPMCodexProfileQuotaHistory(
                id: id,
                snapshot: snapshot,
                sampledAt: importedCodexRefreshState(for: account).lastSuccessAt ?? Date()
            )
        }
        removeCCPMCodexCache(id: id)
    }

    private func removeCCPMCodexCache(id: String) {
        var cache = quotaCache.ccpmCodex ?? [:]
        if cache.removeValue(forKey: id) != nil {
            quotaCache.ccpmCodex = cache.isEmpty ? nil : cache
            saveQuotaCache()
        }
    }

    private func beginCCPMCodexRefresh(id: String, reason: QuotaRefreshReason) -> Bool {
        let now = Date()
        var state = ccpmCodexRefreshStates[id] ?? QuotaRefreshState()
        guard !state.inFlight else { return false }
        if let backoffUntil = state.backoffUntil, backoffUntil > now {
            state.lastError = backoffMessage(until: backoffUntil)
            ccpmCodexRefreshStates[id] = state
            ccpmCodexErrors[id] = state.lastError
            return false
        }
        if reason == .periodic,
           let lastSuccessAt = state.lastSuccessAt,
           now.timeIntervalSince(lastSuccessAt) < minSuccessInterval {
            return false
        }
        state.inFlight = true
        state.lastAttemptAt = now
        ccpmCodexRefreshStates[id] = state
        return true
    }

    private func storeCCPMCodex(id: String, snapshot: QuotaSnapshot, source: QuotaSnapshotSource) {
        let updatedAt = Date()
        ccpmCodexQuotas[id] = snapshot
        ccpmCodexSources[id] = source
        ccpmCodexErrors[id] = nil
        var state = ccpmCodexRefreshStates[id] ?? QuotaRefreshState()
        state.lastSuccessAt = updatedAt
        state.lastError = nil
        state.backoffUntil = nil
        state.source = source
        ccpmCodexRefreshStates[id] = state

        var cache = quotaCache.ccpmCodex ?? [:]
        cache[id] = QuotaCacheRecord(snapshot: snapshot, source: source, updatedAt: updatedAt)
        quotaCache.ccpmCodex = cache
        saveQuotaCache()
        recordCCPMCodexProfileQuotaHistory(id: id, snapshot: snapshot, sampledAt: updatedAt)
    }

    private func markCCPMCodexFailure(id: String, message: String, error: QuotaError? = nil) {
        ccpmCodexErrors[id] = message
        var state = ccpmCodexRefreshStates[id] ?? QuotaRefreshState()
        state.lastError = message
        if error?.isRateLimited == true {
            state.backoffUntil = Date().addingTimeInterval(rateLimitBackoff)
        }
        ccpmCodexRefreshStates[id] = state
    }

    private func loadAllCCPMClaudeProfileQuotas(reason: QuotaRefreshReason) async {
        guard SettingsStore.shared.showClaude else { return }
        let profiles = ccpmClaudeProfiles.filter { $0.authMethod == .oauth }
        guard !profiles.isEmpty else { return }
        let maxConcurrent = 3
        var index = 0
        while index < profiles.count {
            let batch = Array(profiles[index..<min(index + maxConcurrent, profiles.count)])
            await withTaskGroup(of: Void.self) { group in
                for profile in batch {
                    group.addTask { [weak self] in
                        guard let self else { return }
                        await self.loadCCPMClaudeProfileQuota(profile: profile, reason: reason)
                    }
                }
            }
            index += maxConcurrent
        }
    }

    private func loadCCPMClaudeProfileQuota(profile: CCPMClaudeProfile, reason: QuotaRefreshReason) async {
        guard beginCCPMClaudeRefresh(id: profile.id, reason: reason) else { return }
        defer { ccpmClaudeRefreshStates[profile.id]?.inFlight = false }

        let loaded: (ClaudeAccount, ClaudeCredentialStorage)
        do {
            loaded = try await Task.detached(priority: .utility) {
                try CCPMClaudeProfileStore.loadAccount(profile: profile)
            }.value
        } catch {
            markCCPMClaudeFailure(id: profile.id, message: "\(error)")
            return
        }

        var account = loaded.0
        let storage = loaded.1
        ccpmClaudeAccounts[profile.id] = account
        guard account.accessToken != nil else {
            markCCPMClaudeFailure(id: profile.id, message: QuotaError.missingToken.description)
            return
        }

        let refreshed = await ClaudeTokenRefresher.ensureFreshAccessToken(
            account: &account,
            storage: storage
        )
        let activeToken: String
        switch refreshed {
        case .success(let token):
            activeToken = token
            ccpmClaudeAccounts[profile.id] = account
        case .failure(let err):
            markCCPMClaudeFailure(id: profile.id, message: err.description, error: err)
            return
        }

        let result = await ClaudeQuotaClient.fetch(accessToken: activeToken)
        switch result {
        case .success(let snapshot):
            storeCCPMClaude(id: profile.id, snapshot: snapshot, source: .api)
        case .failure(let err):
            markCCPMClaudeFailure(id: profile.id, message: err.description, error: err)
        }
    }

    private func beginCCPMClaudeRefresh(id: String, reason: QuotaRefreshReason) -> Bool {
        let now = Date()
        var state = ccpmClaudeRefreshStates[id] ?? QuotaRefreshState()
        guard !state.inFlight else { return false }
        if let backoffUntil = state.backoffUntil, backoffUntil > now {
            state.lastError = backoffMessage(until: backoffUntil)
            ccpmClaudeRefreshStates[id] = state
            ccpmClaudeErrors[id] = state.lastError
            return false
        }
        if reason == .periodic,
           let lastSuccessAt = state.lastSuccessAt,
           now.timeIntervalSince(lastSuccessAt) < minSuccessInterval
        {
            return false
        }
        state.inFlight = true
        state.lastAttemptAt = now
        ccpmClaudeRefreshStates[id] = state
        return true
    }

    private func storeCCPMClaude(id: String, snapshot: QuotaSnapshot, source: QuotaSnapshotSource) {
        let updatedAt = Date()
        ccpmClaudeQuotas[id] = snapshot
        ccpmClaudeSources[id] = source
        ccpmClaudeErrors[id] = nil
        var state = ccpmClaudeRefreshStates[id] ?? QuotaRefreshState()
        state.lastSuccessAt = updatedAt
        state.lastError = nil
        if source == .api {
            state.backoffUntil = nil
        }
        state.source = source
        ccpmClaudeRefreshStates[id] = state

        var cache = quotaCache.ccpmClaude ?? [:]
        cache[id] = QuotaCacheRecord(snapshot: snapshot, source: source, updatedAt: updatedAt)
        quotaCache.ccpmClaude = cache
        saveQuotaCache()
        recordCCPMClaudeProfileQuotaHistory(id: id, snapshot: snapshot, sampledAt: updatedAt)
    }

    private func markCCPMClaudeFailure(id: String, message: String, error: QuotaError? = nil) {
        ccpmClaudeErrors[id] = message
        var state = ccpmClaudeRefreshStates[id] ?? QuotaRefreshState()
        state.lastError = message
        if error?.isRateLimited == true {
            state.backoffUntil = Date().addingTimeInterval(rateLimitBackoff)
        }
        ccpmClaudeRefreshStates[id] = state
    }

    private func saveQuotaCache() {
        do {
            try QuotaCache.save(quotaCache)
        } catch {
            print("[QuotaCache 额度缓存] 写盘失败 save failed: \(error)")
        }
    }

    private func recordCodexQuotaHistory(snapshot: QuotaSnapshot, sampledAt: Date) {
        recordQuotaHistory(
            accountKey: QuotaHistoryAccountKey.codexPrimary(accountId: codexAccount?.accountId),
            app: .codex,
            kind: .codexPrimary,
            snapshot: snapshot,
            sampledAt: sampledAt
        )
    }

    private func recordClaudeQuotaHistory(snapshot: QuotaSnapshot, sampledAt: Date) {
        recordQuotaHistory(
            accountKey: QuotaHistoryAccountKey.claudePrimary(),
            app: .claude,
            kind: .claudePrimary,
            snapshot: snapshot,
            sampledAt: sampledAt
        )
    }

    private func recordCCPMCodexProfileQuotaHistory(id: String, snapshot: QuotaSnapshot, sampledAt: Date) {
        recordQuotaHistory(
            accountKey: QuotaHistoryAccountKey.codexCCPMProfile(id: id),
            app: .codex,
            kind: .codexCCPMProfile,
            snapshot: snapshot,
            sampledAt: sampledAt
        )
    }

    private func recordCCPMClaudeProfileQuotaHistory(id: String, snapshot: QuotaSnapshot, sampledAt: Date) {
        recordQuotaHistory(
            accountKey: QuotaHistoryAccountKey.claudeCCPMProfile(id: id),
            app: .claude,
            kind: .claudeCCPMProfile,
            snapshot: snapshot,
            sampledAt: sampledAt
        )
    }

    private func recordImportedCodexQuotaHistory(id: String, snapshot: QuotaSnapshot, sampledAt: Date) {
        recordQuotaHistory(
            accountKey: QuotaHistoryAccountKey.codexImported(id: id),
            app: .codex,
            kind: .codexImported,
            snapshot: snapshot,
            sampledAt: sampledAt
        )
    }

    private func recordQuotaHistory(
        accountKey: String,
        app: QuotaApp,
        kind: QuotaHistoryAccountKind,
        snapshot: QuotaSnapshot,
        sampledAt: Date
    ) {
        let next = QuotaHistoryStore.record(
            payload: quotaHistory,
            accountKey: accountKey,
            app: app,
            kind: kind,
            snapshot: snapshot,
            sampledAt: sampledAt
        )
        guard next != quotaHistory else { return }
        quotaHistory = next
        saveQuotaHistory()
    }

    private func saveQuotaHistory() {
        do {
            try QuotaHistoryStore.save(quotaHistory)
        } catch {
            print("[QuotaHistory 额度历史] 写盘失败 save failed: \(error)")
        }
    }

    private func loadCodex() async {
        do {
            let next = try await Task.detached(priority: .utility) {
                try CodexAuth.load()
            }.value
            if codexIdentityChanged(previous: codexAccount, next: next) {
                resetCodexQuotaState()
            }
            self.codexAccount = next
            self.codexError = nil
        } catch {
            self.codexAccount = nil
            self.codexError = "\(error)"
        }
    }

    /// 比较 accountId 优先,缺失时回退到 email。仅当能确认"前后是不同账号"
    /// 时返回 true;previous 为 nil(首次加载)不算变化,避免误清启动缓存。
    private func codexIdentityChanged(previous: CodexAccount?, next: CodexAccount) -> Bool {
        guard let previous else { return false }
        if let a = previous.accountId, let b = next.accountId, !a.isEmpty, !b.isEmpty {
            return a != b
        }
        return previous.email != next.email
    }

    private func resetCodexQuotaState() {
        codexQuota = nil
        codexQuotaSource = nil
        codexQuotaError = nil
        codexRefreshState = QuotaRefreshState()
        quotaCache.codex = nil
        saveQuotaCache()
    }

    /// 没有本地凭据文件、且尚未提示过时,先用一个模态 alert 告诉用户
    /// 接下来会弹出系统 Keychain 授权窗口,避免一上来就被系统弹窗吓到。
    private func maybeShowKeychainPrompt() {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json")
        let hasFile = FileManager.default.fileExists(atPath: url.path)
        let settings = SettingsStore.shared
        guard !hasFile, !settings.didShowKeychainPrompt else { return }

        let alert = NSAlert()
        alert.messageText = tr("Allow Keychain Access", "允许访问 Keychain")
        alert.informativeText = tr(
            "cc-bar reads the Claude credential stored in your macOS Keychain to query your quota. After you continue, macOS will ask for permission — choose \"Always Allow\".",
            "cc-bar 需要读取 macOS 钥匙串里的 Claude 凭据来查询额度。点击「继续」后会弹出系统授权窗口,请选择「始终允许」。"
        )
        alert.alertStyle = .informational
        alert.addButton(withTitle: tr("Continue", "继续"))
        alert.runModal()
        settings.didShowKeychainPrompt = true
    }

    private func loadClaude() async {
        do {
            let next = try await Task.detached(priority: .utility) {
                try ClaudeAuth.load()
            }.value
            if claudeIdentityChanged(previous: claudeAccount, next: next) {
                resetClaudeQuotaState()
            }
            self.claudeAccount = next
            self.claudeError = nil
        } catch {
            self.claudeAccount = nil
            self.claudeError = "\(error)"
        }
    }

    private func claudeIdentityChanged(previous: ClaudeAccount?, next: ClaudeAccount) -> Bool {
        guard let previous else { return false }
        return previous.email != next.email
    }

    private func resetClaudeQuotaState() {
        claudeQuota = nil
        claudeQuotaSource = nil
        claudeQuotaError = nil
        claudeRefreshState = QuotaRefreshState()
        quotaCache.claude = nil
        saveQuotaCache()
    }

    private func loadCodexQuota(reason: QuotaRefreshReason) async {
        guard SettingsStore.shared.showCodex else { return }
        guard beginCodexRefresh(reason: reason) else { return }
        defer { codexRefreshState.inFlight = false }

        guard var account = codexAccount else {
            markCodexFailure("no codex account")
            return
        }
        guard let token = account.accessToken else {
            markCodexFailure(QuotaError.missingToken.description)
            return
        }
        let refreshed = await CodexTokenRefresher.ensureFreshTokens(
            currentAccessToken: token,
            refreshToken: account.refreshToken,
            idToken: account.idToken
        )
        let activeToken: String
        switch refreshed {
        case .success(let t):
            activeToken = t.accessToken
            account.accessToken = t.accessToken
            account.refreshToken = nonEmpty(t.refreshToken)
            account.idToken = t.idToken
            codexAccount = account
        case .failure(let err):
            markCodexFailure(err.description)
            return
        }
        let result = await CodexQuotaClient.fetch(
            accessToken: activeToken,
            accountId: account.accountId
        )
        switch result {
        case .success(let snapshot):
            storeCodex(snapshot: snapshot, source: .api)
        case .failure(let err):
            markCodexFailure(err.description, error: err)
        }
    }

    private func loadClaudeQuota(reason: QuotaRefreshReason) async {
        guard SettingsStore.shared.showClaude else { return }
        guard beginClaudeRefresh(reason: reason) else { return }
        defer { claudeRefreshState.inFlight = false }

        guard var account = claudeAccount else {
            markClaudeFailure("no claude account")
            return
        }
        guard account.accessToken != nil else {
            markClaudeFailure(QuotaError.missingToken.description)
            return
        }
        let refreshed = await ClaudeTokenRefresher.ensureFreshAccessToken(account: &account)
        let activeToken: String
        switch refreshed {
        case .success(let t):
            activeToken = t
            if t != claudeAccount?.accessToken {
                claudeAccount = account
            }
        case .failure(let err):
            markClaudeFailure(err.description, error: err)
            return
        }
        let result = await ClaudeQuotaClient.fetch(accessToken: activeToken)
        switch result {
        case .success(let snapshot):
            storeClaude(snapshot: snapshot, source: .api)
        case .failure(let err):
            markClaudeFailure(err.description, error: err)
            if reason == .userInitiated, claudeQuota == nil {
                await loadClaudeCLIFallback(apiError: err)
            }
        }
    }

    private func loadClaudeCLIFallback(apiError: QuotaError) async {
        let now = Date()
        if let claudeFallbackBackoffUntil, claudeFallbackBackoffUntil > now {
            markClaudeFailure("\(apiError.description); cli fallback cooling down until \(claudeFallbackBackoffUntil)")
            return
        }

        claudeFallbackBackoffUntil = now.addingTimeInterval(rateLimitBackoff)
        let result = await ClaudeCLIFallbackQuotaClient.fetch()
        switch result {
        case .success(let snapshot):
            storeClaude(snapshot: snapshot, source: .cliFallback)
        case .failure(let err):
            markClaudeFailure("\(apiError.description); cli fallback failed: \(err.description)", error: err)
        }
    }

    private func beginCodexRefresh(reason: QuotaRefreshReason) -> Bool {
        let now = Date()
        guard !codexRefreshState.inFlight else { return false }
        if let backoffUntil = codexRefreshState.backoffUntil, backoffUntil > now {
            markCodexFailure(backoffMessage(until: backoffUntil))
            return false
        }
        if reason == .periodic,
           let lastSuccessAt = codexRefreshState.lastSuccessAt,
           now.timeIntervalSince(lastSuccessAt) < minSuccessInterval
        {
            return false
        }
        codexRefreshState.inFlight = true
        codexRefreshState.lastAttemptAt = now
        return true
    }

    private func beginClaudeRefresh(reason: QuotaRefreshReason) -> Bool {
        let now = Date()
        guard !claudeRefreshState.inFlight else { return false }
        if let backoffUntil = claudeRefreshState.backoffUntil, backoffUntil > now {
            markClaudeFailure(backoffMessage(until: backoffUntil))
            return false
        }
        if reason == .periodic,
           let lastSuccessAt = claudeRefreshState.lastSuccessAt,
           now.timeIntervalSince(lastSuccessAt) < minSuccessInterval
        {
            return false
        }
        claudeRefreshState.inFlight = true
        claudeRefreshState.lastAttemptAt = now
        return true
    }

    private func storeCodex(snapshot: QuotaSnapshot, source: QuotaSnapshotSource) {
        let updatedAt = Date()
        codexQuota = snapshot
        codexQuotaSource = source
        codexQuotaError = nil
        codexRefreshState.lastSuccessAt = updatedAt
        codexRefreshState.lastError = nil
        codexRefreshState.backoffUntil = nil
        codexRefreshState.source = source
        quotaCache.codex = QuotaCacheRecord(snapshot: snapshot, source: source, updatedAt: updatedAt)
        saveQuotaCache()
        recordCodexQuotaHistory(snapshot: snapshot, sampledAt: updatedAt)
    }

    private func storeClaude(snapshot: QuotaSnapshot, source: QuotaSnapshotSource) {
        let updatedAt = Date()
        claudeQuota = snapshot
        claudeQuotaSource = source
        claudeQuotaError = nil
        claudeRefreshState.lastSuccessAt = updatedAt
        claudeRefreshState.lastError = nil
        if source == .api {
            claudeRefreshState.backoffUntil = nil
        }
        claudeRefreshState.source = source
        quotaCache.claude = QuotaCacheRecord(snapshot: snapshot, source: source, updatedAt: updatedAt)
        saveQuotaCache()
        recordClaudeQuotaHistory(snapshot: snapshot, sampledAt: updatedAt)
    }

    private func markCodexFailure(_ message: String, error: QuotaError? = nil) {
        codexQuotaError = message
        codexRefreshState.lastError = message
        if error?.isRateLimited == true {
            codexRefreshState.backoffUntil = Date().addingTimeInterval(rateLimitBackoff)
        }
    }

    private func markClaudeFailure(_ message: String, error: QuotaError? = nil) {
        claudeQuotaError = message
        claudeRefreshState.lastError = message
        if error?.isRateLimited == true {
            claudeRefreshState.backoffUntil = Date().addingTimeInterval(rateLimitBackoff)
        }
    }

    private func backoffMessage(until: Date) -> String {
        "rate limited; retry in \(relativeAge(until: until))"
    }

    private func logCredentialSummary() {
        if let c = codexAccount {
            print("[Credentials 凭据] Codex: email=\(c.email ?? "—") plan=\(c.planType ?? "—") account_id=\(c.accountId ?? "—") expiredGuess=\(c.expiredGuess) hasAccessToken=\(c.accessToken != nil) hasRefreshToken=\(c.refreshToken != nil)")
        } else {
            print("[Credentials 凭据] Codex 未加载: error=\(codexError ?? "unknown")")
        }
        if let c = claudeAccount {
            print("[Credentials 凭据] Claude: source=\(c.source.rawValue) email=\(c.email ?? "—") plan=\(c.subscriptionType ?? "—") expiresAt=\(c.expiresAt.map { "\($0)" } ?? "—") expiredGuess=\(c.expiredGuess) hasAccessToken=\(c.accessToken != nil)")
        } else {
            print("[Credentials 凭据] Claude 未加载: error=\(claudeError ?? "unknown")")
        }
    }

    private func logQuotaSummary() {
        let settings = SettingsStore.shared
        if !settings.showCodex {
            print("[Quota 额度] Codex 已关闭: skipped")
        } else if let q = codexQuota {
            print("[Quota 额度] Codex: source=\(codexQuotaSource?.rawValue ?? "—") plan=\(q.planType ?? "—") \(format(q))")
        } else {
            print("[Quota 额度] Codex 拉取失败: error=\(codexQuotaError ?? "unknown")")
        }
        if !settings.showClaude {
            print("[Quota 额度] Claude 已关闭: skipped")
        } else if let q = claudeQuota {
            print("[Quota 额度] Claude: source=\(claudeQuotaSource?.rawValue ?? "—") \(format(q))")
            if let opus = q.weeklyOpus { print("       └─ weeklyOpus=\(format(window: opus))") }
            if let sonnet = q.weeklySonnet { print("       └─ weeklySonnet=\(format(window: sonnet))") }
        } else {
            print("[Quota 额度] Claude 拉取失败: error=\(claudeQuotaError ?? "unknown")")
        }
    }

    private func format(_ q: QuotaSnapshot) -> String {
        let parts = [
            q.fiveHour.map { "5h=\(format(window: $0))" },
            q.weekly.map { "1w=\(format(window: $0))" }
        ].compactMap { $0 }
        return parts.joined(separator: " ")
    }

    private func format(window w: QuotaWindow) -> String {
        let pct = String(format: "%.1f%% left", w.remainingPercent)
        let reset: String
        if let r = w.resetsAt {
            let mins = Int(r.timeIntervalSinceNow / 60)
            reset = mins > 0 ? "resets in ~\(mins)m" : "resets now"
        } else {
            reset = "resets ?"
        }
        return "\(pct) (\(reset))"
    }

    private func relativeAge(from date: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        return "\(minutes / 60)h"
    }

    private func relativeAge(until date: Date) -> String {
        let seconds = max(0, Int(date.timeIntervalSince(Date())))
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        return "\(minutes / 60)h"
    }

    private func shortError(_ error: String) -> String {
        let oneLine = error.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if oneLine.count <= 120 { return oneLine }
        return String(oneLine.prefix(117)) + "..."
    }
}
