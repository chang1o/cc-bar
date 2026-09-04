import AppKit
import Foundation
import Observation

nonisolated struct AccountQuotaState: Sendable, Equatable {
    var snapshot: QuotaSnapshot?
    var source: QuotaSnapshotSource?
    var error: String?
    var refresh = QuotaRefreshState()
}

@Observable
@MainActor
final class AppState {
    /// Every discovered account, grouped in `Provider.allCases` order.
    var accounts: [MonitoredAccount] = []
    /// Quota state per account. Mirrored accounts have no entry of their own;
    /// read through `quotaState(for:)`.
    var quota: [AccountID: AccountQuotaState] = [:]
    /// Statuspage snapshots for providers that publish one; failures keep the last value.
    var serviceStatus: [Provider: ServiceStatus] = [:]
    /// Today's local cost per account, published by `UsageService`.
    var todayCost: [AccountID: Decimal] = [:]
    var quotaHistory = QuotaHistoryPayload()

    /// Metadata of manually imported Codex accounts; the Settings list edits this.
    var importedCodexAccounts: [ImportedCodexAccount] = []

    var mainTab: MainTab = .stats
    var shouldShowOnboarding: Bool = false

    let usageService = UsageService()
    private let scheduler = Scheduler()
    private var didBootstrap = false
    private var quotaCache = QuotaCachePayload()
    private var claudeFallbackBackoffUntil: Date?
    private var refreshInFlight: Task<Void, Never>?
    private var delegatedRefreshObserver: NSObjectProtocol?

    private let minSuccessInterval: TimeInterval = 60
    private let rateLimitBackoff: TimeInterval = 10 * 60
    private let maxConcurrentFetches = 3

    // MARK: - Lifecycle

    func bootstrap() async {
        guard !didBootstrap else { return }
        didBootstrap = true

        subscribeToDelegatedRefreshSuccess()
        loadQuotaCache()
        quotaHistory = QuotaHistoryStore.load()
        saveQuotaHistory()
        importedCodexAccounts = ImportedCodexStore.loadAll()
        usageService.bootstrap(appState: self)
        maybeShowKeychainPrompt()
        await rediscover()
        logAccountSummary()

        if !SettingsStore.shared.didCompleteOnboarding {
            shouldShowOnboarding = true
        }

        let settings = SettingsStore.shared
        scheduler.start(
            appState: self,
            quotaInterval: settings.quotaInterval.seconds,
            usageInterval: settings.usageInterval.seconds
        )
        Task { await usageService.scanNow() }
        Task { await refreshServiceStatus() }
        // First fetch right away; the 60s throttle skips accounts whose cache is still fresh.
        Task { await refreshQuotas(reason: .periodic) }
    }

    func applySettingsChange() {
        let settings = SettingsStore.shared
        scheduler.setQuotaInterval(settings.quotaInterval.seconds)
        scheduler.setUsageInterval(settings.usageInterval.seconds)
    }

    /// Manual refresh; concurrent calls collapse into the one already running.
    func refreshNow() async {
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

    private func subscribeToDelegatedRefreshSuccess() {
        delegatedRefreshObserver = NotificationCenter.default.addObserver(
            forName: .claudeDelegatedRefreshDidSucceed,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refreshQuotas(reason: .periodic)
            }
        }
    }

    // MARK: - Derived views

    func account(for id: AccountID) -> MonitoredAccount? {
        accounts.first { $0.id == id }
    }

    func accounts(for provider: Provider) -> [MonitoredAccount] {
        accounts.filter { $0.provider == provider }
    }

    /// Providers with at least one discovered account, in display order.
    var presentProviders: [Provider] {
        Provider.allCases.filter { provider in accounts.contains { $0.provider == provider } }
    }

    /// Present and enabled in Settings.
    var visibleProviders: [Provider] {
        let settings = SettingsStore.shared
        return presentProviders.filter { settings.isEnabled($0) }
    }

    var visibleAccounts: [MonitoredAccount] {
        let settings = SettingsStore.shared
        return accounts.filter { settings.isEnabled($0.provider) }
    }

    func quotaState(for account: MonitoredAccount) -> AccountQuotaState {
        if let mirror = account.mirrorsAccount {
            return quota[mirror] ?? AccountQuotaState()
        }
        return quota[account.id] ?? AccountQuotaState()
    }

    func quotaState(for id: AccountID) -> AccountQuotaState {
        guard let account = account(for: id) else { return quota[id] ?? AccountQuotaState() }
        return quotaState(for: account)
    }

    /// Most constrained lanes across every account of a provider.
    func monitorSnapshot(for provider: Provider) -> QuotaSnapshot? {
        QuotaSnapshot.mostConstrained(accounts(for: provider).compactMap { quotaState(for: $0).snapshot })
    }

    func latestSuccess(for provider: Provider) -> Date? {
        accounts(for: provider).compactMap { quotaState(for: $0).refresh.lastSuccessAt }.max()
    }

    func hasError(for provider: Provider) -> Bool {
        accounts(for: provider).contains { quotaState(for: $0).refresh.lastError != nil }
    }

    /// Newest successful fetch across visible providers; drives the header dot.
    var latestVisibleSuccess: Date? {
        visibleProviders.compactMap { latestSuccess(for: $0) }.max()
    }

    var hasVisibleError: Bool {
        visibleProviders.contains { hasError(for: $0) }
    }

    // MARK: - Discovery

    func rediscover() async {
        let imported = importedCodexAccounts
        let discovery = await Task.detached(priority: .utility) {
            AccountCatalog.discover(importedAccounts: imported)
        }.value
        apply(discovery)
    }

    private func apply(_ discovery: AccountCatalog.Discovery) {
        let previous = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })
        var cacheChanged = false

        for account in discovery.accounts {
            guard let old = previous[account.id],
                  let oldFingerprint = old.identity.fingerprint,
                  let newFingerprint = account.identity.fingerprint,
                  oldFingerprint != newFingerprint
            else { continue }
            // Same slot, different identity (e.g. cc-switch changed the login): drop stale quota.
            quota[account.id] = nil
            if quotaCache.records.removeValue(forKey: account.id.raw) != nil { cacheChanged = true }
        }

        let alive = Set(discovery.accounts.map(\.id))
        quota = quota.filter { alive.contains($0.key) }
        let before = quotaCache.records.count
        quotaCache.records = quotaCache.records.filter { AccountID(raw: $0.key).isAlive(in: alive) }
        if quotaCache.records.count != before { cacheChanged = true }

        accounts = discovery.accounts
        if cacheChanged { saveQuotaCache() }
    }

    // MARK: - Quota refresh

    func refreshQuotas(reason: QuotaRefreshReason = .periodic) async {
        await rediscover()
        let settings = SettingsStore.shared

        var targets: [MonitoredAccount] = []
        for account in accounts where settings.isEnabled(account.provider) && account.mirrorsAccount == nil {
            if case .unavailable(let reason) = account.credential {
                var state = quota[account.id] ?? AccountQuotaState()
                state.error = reason
                state.refresh.lastError = reason
                quota[account.id] = state
                continue
            }
            targets.append(account)
        }

        var index = 0
        while index < targets.count {
            let batch = Array(targets[index..<min(index + maxConcurrentFetches, targets.count)])
            await withTaskGroup(of: Void.self) { group in
                for account in batch {
                    group.addTask { [weak self] in
                        await self?.loadQuota(account: account, reason: reason)
                    }
                }
            }
            index += maxConcurrentFetches
        }

        syncMirrors()
        logQuotaSummary()
    }

    private func loadQuota(account: MonitoredAccount, reason: QuotaRefreshReason) async {
        let id = account.id
        guard beginRefresh(id: id, reason: reason) else { return }
        defer { quota[id]?.refresh.inFlight = false }

        let result = await QuotaFetcher.fetch(account: account)
        switch result {
        case .success(let success):
            if let credential = success.credential,
               let index = accounts.firstIndex(where: { $0.id == id }) {
                accounts[index].credential = credential
            }
            store(id: id, snapshot: success.snapshot, source: success.source)
        case .failure(let error):
            markFailure(id: id, message: error.description, error: error)
            if account.provider == .claude, account.isDefaultLogin,
               reason == .userInitiated, quota[id]?.snapshot == nil {
                await loadClaudeCLIFallback(id: id, apiError: error)
            }
        }
    }

    /// Last resort for the default Claude login: drive the local `claude` CLI
    /// once when the API failed and nothing is cached. Own 10-minute cooldown.
    private func loadClaudeCLIFallback(id: AccountID, apiError: QuotaError) async {
        let now = Date()
        if let claudeFallbackBackoffUntil, claudeFallbackBackoffUntil > now {
            markFailure(id: id, message: "\(apiError.description); cli fallback cooling down until \(claudeFallbackBackoffUntil)")
            return
        }
        claudeFallbackBackoffUntil = now.addingTimeInterval(rateLimitBackoff)
        let result = await ClaudeCLIFallbackQuotaClient.fetch()
        switch result {
        case .success(let snapshot):
            store(id: id, snapshot: snapshot, source: .cliFallback)
        case .failure(let error):
            markFailure(id: id, message: "\(apiError.description); cli fallback failed: \(error.description)", error: error)
        }
    }

    private func beginRefresh(id: AccountID, reason: QuotaRefreshReason) -> Bool {
        let now = Date()
        var state = quota[id] ?? AccountQuotaState()
        guard !state.refresh.inFlight else { return false }
        if let backoffUntil = state.refresh.backoffUntil, backoffUntil > now {
            let message = "rate limited; retry in \(relativeAge(until: backoffUntil))"
            state.refresh.lastError = message
            state.error = message
            quota[id] = state
            return false
        }
        if reason == .periodic,
           let lastSuccessAt = state.refresh.lastSuccessAt,
           now.timeIntervalSince(lastSuccessAt) < minSuccessInterval {
            return false
        }
        state.refresh.inFlight = true
        state.refresh.lastAttemptAt = now
        quota[id] = state
        return true
    }

    private func store(id: AccountID, snapshot: QuotaSnapshot, source: QuotaSnapshotSource) {
        let updatedAt = Date()
        var state = quota[id] ?? AccountQuotaState()
        let previous = state.snapshot
        state.snapshot = snapshot
        state.source = source
        state.error = nil
        state.refresh.lastSuccessAt = updatedAt
        state.refresh.lastError = nil
        if source == .api {
            state.refresh.backoffUntil = nil
        }
        state.refresh.source = source
        quota[id] = state

        quotaCache.records[id.raw] = QuotaCacheRecord(snapshot: snapshot, source: source, updatedAt: updatedAt)
        saveQuotaCache()
        recordHistory(id: id, snapshot: snapshot, sampledAt: updatedAt)
        if source == .api, let account = account(for: id) {
            QuotaNotifier.shared.evaluate(account: account, previous: previous, next: snapshot)
        }
    }

    private func markFailure(id: AccountID, message: String, error: QuotaError? = nil) {
        var state = quota[id] ?? AccountQuotaState()
        state.error = message
        state.refresh.lastError = message
        if error?.isRateLimited == true {
            state.refresh.backoffUntil = Date().addingTimeInterval(rateLimitBackoff)
        }
        quota[id] = state
    }

    /// Mirrored accounts share the target's quota; they still get their own
    /// history line, and imported mirrors of the default Codex login receive
    /// the fresh tokens so they keep working once the default login changes.
    private func syncMirrors() {
        for account in accounts {
            guard let mirror = account.mirrorsAccount, let target = quota[mirror] else { continue }
            if let snapshot = target.snapshot, target.source == .api {
                recordHistory(id: account.id, snapshot: snapshot, sampledAt: target.refresh.lastSuccessAt ?? Date())
            }
            if case .importedCodex(let importedId) = account.source,
               let defaultCodex = self.account(for: mirror),
               case .codexOAuth(let codex, _) = defaultCodex.credential,
               let accessToken = nonEmpty(codex.accessToken) {
                let tokens = ImportedCodexTokens(
                    accessToken: accessToken,
                    refreshToken: nonEmpty(codex.refreshToken),
                    idToken: nonEmpty(codex.idToken)
                )
                do { try ImportedCodexStore.saveTokens(tokens, accountId: importedId) } catch {
                    print("[imported-codex] sync primary tokens failed: \(error)")
                }
            }
        }
    }

    // MARK: - Service status

    func refreshServiceStatus() async {
        let providers = visibleProviders.filter { $0.descriptor.statusPageURL != nil }
        guard !providers.isEmpty else { return }
        let results = await withTaskGroup(of: (Provider, ServiceStatus?).self) { group in
            for provider in providers {
                group.addTask {
                    guard let url = provider.descriptor.statusPageURL else { return (provider, nil) }
                    do {
                        return (provider, try await ServiceStatusClient.fetch(from: url))
                    } catch {
                        print("[service-status] \(provider.rawValue) fetch failed: \(error)")
                        return (provider, nil)
                    }
                }
            }
            var collected: [Provider: ServiceStatus] = [:]
            for await (provider, status) in group {
                if let status { collected[provider] = status }
            }
            return collected
        }
        for (provider, status) in results {
            serviceStatus[provider] = status
        }
    }

    // MARK: - Imported Codex accounts

    func reloadImportedCodexAccounts() {
        importedCodexAccounts = ImportedCodexStore.loadAll()
        Task { await rediscover() }
    }

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

    func removeImportedCodexAccount(id: String) {
        ImportedCodexStore.deleteTokens(accountId: id)
        let list = ImportedCodexStore.loadAll().filter { $0.id != id }
        do { try ImportedCodexStore.saveAll(list) } catch {
            print("[imported-codex] delete failed: \(error)")
        }
        reloadImportedCodexAccounts()
    }

    // MARK: - Ollama cookie

    func setOllamaCookie(_ cookieHeader: String, profile: String) throws {
        try OllamaCookieStore.save(cookieHeader, profile: profile)
        let id = AccountID(provider: .ollama, source: .ccpm(profile: profile))
        quota[id]?.error = nil
        quota[id]?.refresh.lastError = nil
        quota[id]?.refresh.backoffUntil = nil
        Task { await refreshQuotas(reason: .userInitiated) }
    }

    // MARK: - Persistence

    private func loadQuotaCache() {
        quotaCache = QuotaCache.load()
        for (key, record) in quotaCache.records {
            var state = AccountQuotaState()
            state.snapshot = record.snapshot
            state.source = .cache
            state.refresh.lastSuccessAt = record.updatedAt
            state.refresh.source = .cache
            quota[AccountID(raw: key)] = state
        }
    }

    private func saveQuotaCache() {
        do {
            try QuotaCache.save(quotaCache)
        } catch {
            print("[QuotaCache] save failed: \(error)")
        }
    }

    private func recordHistory(id: AccountID, snapshot: QuotaSnapshot, sampledAt: Date) {
        let next = QuotaHistoryStore.record(
            payload: quotaHistory,
            accountKey: id.raw,
            provider: snapshot.provider,
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
            print("[QuotaHistory] save failed: \(error)")
        }
    }

    // MARK: - Keychain onboarding prompt

    /// Without a local credentials file the first Keychain read shows a system
    /// prompt; explain it once before it appears.
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

    // MARK: - Logging

    private func logAccountSummary() {
        for account in accounts {
            let credential: String
            switch account.credential {
            case .codexOAuth: credential = "codex-oauth"
            case .claudeOAuth: credential = "claude-oauth"
            case .apiKey: credential = "api-key"
            case .ollamaCookie(let cookie, _): credential = cookie == nil ? "cookie-missing" : "cookie"
            case .unavailable(let reason): credential = "unavailable(\(shortError(reason)))"
            }
            let mirror = account.mirrorsAccount.map { " mirrors=\($0.raw)" } ?? ""
            print("[Accounts] \(account.id.raw) email=\(account.identity.email ?? "—") plan=\(account.identity.plan ?? "—") credential=\(credential)\(mirror)")
        }
    }

    private func logQuotaSummary() {
        let settings = SettingsStore.shared
        for account in accounts where account.mirrorsAccount == nil {
            guard settings.isEnabled(account.provider) else { continue }
            let state = quota[account.id] ?? AccountQuotaState()
            if let snapshot = state.snapshot {
                let lanes = snapshot.allWindows
                    .map { "\($0.kind.shortLabel)=\(String(format: "%.1f%%", $0.remainingPercent))" }
                    .joined(separator: " ")
                print("[Quota] \(account.id.raw) source=\(state.source?.rawValue ?? "—") \(lanes)")
            } else {
                print("[Quota] \(account.id.raw) failed: \(state.error ?? "unknown")")
            }
        }
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
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

private extension AccountID {
    func isAlive(in ids: Set<AccountID>) -> Bool {
        ids.contains(self)
    }
}
