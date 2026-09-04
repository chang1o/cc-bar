import SwiftUI
import AppKit

// MARK: - PopoverRootView
//
// Header (title + status dot + refresh / stats / settings / quit) followed by one
// section per present provider. Every account inside a section renders as a full
// card (`ServiceBlockView`): primary account first, then ccpm profiles, then the
// imported Codex accounts. No compact rows.

struct PopoverRootView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow
    @State private var refreshRotation: Double = 0

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            content
        }
        .frame(width: 340)
        // 转圈由 appState.isRefreshing 统一驱动:无论刷新从哪个入口发起
        // (点击刷新按钮、⌘R 全局快捷键),只要整体刷新真正开始,按钮就转一圈。
        .onChange(of: appState.isRefreshing) { _, refreshing in
            if refreshing { refreshRotation += 360 }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 4) {
            VStack(alignment: .leading, spacing: 1) {
                Text(tr("Usage", "用量"))
                    .font(.system(size: 13, weight: .semibold))

                // 用 TimelineView 每秒重新渲染一次,让 "Xs 前已刷新" 实时滚动。
                // Popover 不可见时 TimelineView 不会被调度,几乎零 CPU 成本。
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(headerSubtitle(now: context.date))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                }
            }

            Spacer()

            if let state = headerState {
                Circle()
                    .fill(state.color)
                    .frame(width: 7, height: 7)
                    .help(state.tooltip)
                    .padding(.trailing, 4)
            }

            Button(action: refresh) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(refreshRotation))
                    .animation(.easeInOut(duration: 0.7), value: refreshRotation)
            }
            .buttonStyle(PopoverIconButtonStyle())
            // 不加 disabled:按钮永远可点;AppState.refreshNow() 内部已经做了
            // in-flight 去重,不会重复发请求。刷新真正开始时由 isRefreshing 驱动转圈。
            .help(tr("Refresh now", "立即刷新"))

            Button { activateAndOpenMain(tab: .stats) } label: {
                Image(systemName: "chart.bar.xaxis")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(PopoverIconButtonStyle())
            .help(tr("Open Statistics", "查看统计"))

            Button { activateAndOpenMain(tab: .settings) } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(PopoverIconButtonStyle())
            .help(tr("Settings", "设置"))

            Button { NSApp.terminate(nil) } label: {
                Image(systemName: "power")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(PopoverIconButtonStyle())
            .help(tr("Quit", "退出"))
        }
        .padding(.top, 14)
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }

    /// `now` 由 header 的 TimelineView 提供,让"Xs 前已刷新"实时滚动。
    private func headerSubtitle(now: Date) -> String {
        let states = monitoredRefreshStates
        let latest = states.compactMap(\.lastSuccessAt).max()

        if let latest {
            let age = Self.relativeAge(from: latest, now: now)
            return tr("refreshed \(age) ago", "\(age) 前已刷新")
        }
        if states.contains(where: { $0.lastError != nil }) {
            return tr("refresh failed", "刷新失败")
        }
        return tr("waiting…", "等待数据")
    }

    /// Refresh states of every account the popover shows: primaries plus the ccpm
    /// profiles that are fetched on their own (mirrors reuse the primary state).
    private var monitoredRefreshStates: [QuotaRefreshState] {
        var states: [QuotaRefreshState] = []
        for app in appState.presentProviders {
            if appState.hasPrimaryAccount(app) {
                states.append(appState.refreshState(for: app))
            }
            for account in appState.ccpmAccounts(for: app)
            where !account.mirrorsPrimary && account.availability == .ready {
                states.append(appState.ccpmQuotaState(for: account).refresh)
            }
        }
        return states
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        let apps = appState.presentProviders
        let hasImported = appState.importedCodexAccounts.contains(where: \.visibleInPopover)
        let includesCodex = apps.contains(.codex)

        if apps.isEmpty && !hasImported {
            VStack(spacing: 6) {
                Text(tr("No accounts to show", "没有可显示的账号"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(tr("Enable a service in Settings → Accounts, or add a ccpm profile",
                        "到「设置 → 账号」开启服务,或添加 ccpm profile"))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
            .padding(.horizontal, 16)
        } else {
            VStack(spacing: 0) {
                if hasImported && !includesCodex {
                    OtherCodexAccountsSection()
                    if !apps.isEmpty {
                        Divider().padding(.horizontal, 16)
                    }
                }

                ForEach(Array(apps.enumerated()), id: \.element) { index, app in
                    if index > 0 {
                        Divider().padding(.horizontal, 16)
                    }
                    providerSection(app)
                }
            }
        }
    }

    /// One provider: optional "N accounts" header, primary card, ccpm cards, imported Codex rows.
    @ViewBuilder
    private func providerSection(_ app: QuotaApp) -> some View {
        let hasPrimary = appState.hasPrimaryAccount(app)
        let ccpm = appState.ccpmAccounts(for: app)
        let standaloneCCPM = ccpm.filter { !$0.mirrorsPrimary }.count
        let otherCodex = app == .codex ? visibleImportedCodexCount(dedupPrimary: hasPrimary) : 0
        let cardCount = (hasPrimary ? 1 : 0) + standaloneCCPM + otherCodex

        VStack(spacing: 0) {
            if cardCount > 1, let descriptor = QuotaProviderDescriptor.descriptor(for: app) {
                ProviderAccountsHeader(
                    title: "\(descriptor.title.uppercased()) ACCOUNTS",
                    chineseTitle: "\(descriptor.title) 账号",
                    count: cardCount
                )
            }

            if hasPrimary, let descriptor = QuotaProviderDescriptor.descriptor(for: app) {
                primaryServiceBlock(descriptor)
            }

            CCPMAccountsSection(app: app, hasPrecedingCard: hasPrimary)

            if app == .codex && otherCodex > 0 {
                Divider().padding(.horizontal, 16)
                OtherCodexAccountsSection(dedupPrimary: hasPrimary)
            }
        }
    }

    private func visibleImportedCodexCount(dedupPrimary: Bool) -> Int {
        appState.importedCodexAccounts.filter {
            $0.visibleInPopover && !(dedupPrimary && appState.importedCodexAccountMirrorsPrimary($0))
        }.count
    }

    /// Identity line under the title: email (unless privacy mode) or the vendor name.
    /// The plan lives in the card's chip, not here.
    private func providerSubtitle(for app: QuotaApp) -> String {
        let privacy = SettingsStore.shared.privacyMode
        let email: String?
        let fallback: String
        switch app {
        case .codex:
            email = appState.codexAccount?.email
            fallback = "OpenAI"
        case .claude:
            email = appState.claudeAccount?.email
            fallback = "Anthropic"
        case .antigravity:
            email = appState.antigravityAccount?.email
            fallback = "Google"
        case .cursor:
            email = appState.cursorAccount?.email
            fallback = "Cursor"
        case .commandCode:
            email = appState.commandCodeAccount?.email ?? appState.commandCodeAccount?.login
            fallback = "Command Code"
        case .kimi, .glm, .ollama:
            email = nil
            fallback = QuotaProviderDescriptor.descriptor(for: app)?.vendor ?? ""
        }
        if !privacy, let email, !email.isEmpty { return email }
        return fallback
    }

    private func planBadge(for app: QuotaApp) -> String? {
        let raw: String?
        switch app {
        case .codex:
            raw = appState.quotaSnapshot(for: .codex)?.planType ?? appState.codexAccount?.planType
        case .claude:
            raw = appState.quotaSnapshot(for: .claude)?.planType ?? appState.claudeAccount?.subscriptionType
        case .antigravity:
            raw = appState.quotaSnapshot(for: .antigravity)?.planType ?? appState.antigravityAccount?.planType
        case .cursor:
            raw = appState.quotaSnapshot(for: .cursor)?.planType
        case .commandCode:
            raw = appState.commandCodeAccount?.planType ?? appState.quotaSnapshot(for: .commandCode)?.planType
        case .kimi, .glm, .ollama:
            raw = appState.quotaSnapshot(for: app)?.planType
        }
        return ServiceBlockView.formatPlan(raw)
    }

    private func primaryServiceBlock(_ provider: QuotaProviderDescriptor) -> some View {
        ServiceBlockView(
            app: provider.app,
            title: provider.title,
            subtitle: providerSubtitle(for: provider.app),
            tint: provider.app.tintColor,
            logoName: provider.logoName,
            fallback: provider.fallback,
            state: appState.primaryQuotaStates[provider.app] ?? PrimaryQuotaState(),
            error: providerDisplayError(for: provider.app),
            usage: usage(for: provider),
            serviceStatus: serviceStatus(for: provider.app),
            planBadge: planBadge(for: provider.app),
            dashboardURL: provider.dashboardURL,
            statusPageURL: provider.statusPageWebURL
        )
    }

    private func providerDisplayError(for app: QuotaApp) -> String? {
        guard let error = appState.quotaError(for: app) else { return nil }
        guard app == .cursor || app == .commandCode else { return error }
        return tr("refresh failed", "刷新失败")
    }

    /// Local usage totals for the primary card. ccpm cards never show usage: the
    /// scanners aggregate per app, so a per-profile split does not exist.
    private func usage(for provider: QuotaProviderDescriptor) -> ServiceBlockView.Usage? {
        guard provider.showsCost else { return nil }
        let (todayFrom, todayTo) = Self.todayBounds()
        let (weekFrom, weekTo) = Self.weekBounds()
        let (monthFrom, monthTo) = Self.monthBounds()
        if provider.app == .cursor {
            return ServiceBlockView.Usage(
                today: cursorTotals(from: todayFrom, to: todayTo),
                week: cursorTotals(from: weekFrom, to: weekTo),
                month: cursorTotals(from: monthFrom, to: monthTo),
                showsTokens: false
            )
        }
        guard let usageApp = provider.app.usageApp else { return nil }
        let aggregator = appState.usageService.aggregator
        return ServiceBlockView.Usage(
            today: aggregator.totals(app: usageApp, from: todayFrom, to: todayTo),
            week: aggregator.totals(app: usageApp, from: weekFrom, to: weekTo),
            month: aggregator.totals(app: usageApp, from: monthFrom, to: monthTo),
            showsTokens: true
        )
    }

    /// Cursor 没有本地日志费用。只要远端缓存已有相交日桶，就展示已知 `chargedCents`
    /// 汇总；完整覆盖由刷新链路在后台补齐，不能让一个缺口抹掉已有金额。
    private func cursorTotals(from: Date, to: Date) -> UsageTotals? {
        guard appState.usageService.hasCursorRemoteUsage(in: from..<to) else { return nil }
        return appState.usageService.aggregator.totals(app: .cursor, from: from, to: to)
    }

    private func serviceStatus(for app: QuotaApp) -> ServiceStatus? {
        guard SettingsStore.shared.showServiceStatus else { return nil }
        return switch app {
        case .codex: appState.codexServiceStatus
        case .claude: appState.claudeServiceStatus
        case .cursor: appState.cursorServiceStatus
        case .antigravity, .commandCode, .kimi, .glm, .ollama: nil
        }
    }

    // MARK: Header state (live / stale / offline)

    private var headerState: CCRefreshState? {
        let settings = SettingsStore.shared
        let states = monitoredRefreshStates
        let latest = states.compactMap(\.lastSuccessAt).max()
        let hasError = states.contains(where: { $0.lastError != nil })

        guard let latest else {
            return hasError ? .offline : nil
        }

        let interval = settings.quotaInterval.seconds ?? 300
        let age = Date().timeIntervalSince(latest)
        if age <= interval * 1.5 { return .live }
        if age <= interval * 3 { return .stale }
        return .offline
    }

    // MARK: Open main window

    /// 菜单栏 App (`.accessory`) 默认不抢焦点,打开窗口后会被压在其他 App 后面;
    /// 先 `activate(ignoringOtherApps:)` 把进程置前,再 `openWindow` 才会出现在最前。
    /// 先设置 `mainTab` 再 openWindow,确保点「统计」/「设置」总是落到对应 tab,
    /// 不受上次窗口停留 tab 影响(与 ⌘, / ⌘1 命令行为一致)。
    private func activateAndOpenMain(tab: MainTab) {
        appState.mainTab = tab
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "main")
    }

    // MARK: Refresh

    /// 用户点刷新按钮的处理:
    /// - 只负责启动一个非阻塞 Task 去做真正的刷新工作;UI 不等
    /// - 真正的去重 / 协调放在 `AppState.refreshNow()` 内部
    /// - 转圈动画不在这里手动触发,而由 body 上监听 `appState.isRefreshing` 统一驱动,
    ///   让点击和 ⌘R 两个入口的视觉反馈完全一致(刷新真正开始才转,in-flight 去重时不转)
    /// - 数据更新通过 @Observable 自动驱动 UI 刷新,不需要在这里 await 结果
    private func refresh() {
        Task { await appState.refreshNow() }
    }

    // MARK: Helpers

    static func todayBounds(now: Date = Date()) -> (Date, Date) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let start = cal.startOfDay(for: now)
        return (start, cal.date(byAdding: .day, value: 1, to: start) ?? start)
    }

    static func weekBounds(now: Date = Date()) -> (Date, Date) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        cal.firstWeekday = 2
        let startOfToday = cal.startOfDay(for: now)
        let startOfTomorrow = cal.date(byAdding: .day, value: 1, to: startOfToday) ?? startOfToday
        let comps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)
        let weekStart = cal.date(from: comps) ?? startOfToday
        return (weekStart, startOfTomorrow)
    }

    /// Rolling 30 days ending tomorrow 00:00 (today included).
    static func monthBounds(now: Date = Date()) -> (Date, Date) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let startOfToday = cal.startOfDay(for: now)
        let startOfTomorrow = cal.date(byAdding: .day, value: 1, to: startOfToday) ?? startOfToday
        let start = cal.date(byAdding: .day, value: -29, to: startOfToday) ?? startOfToday
        return (start, startOfTomorrow)
    }

    /// 计算相对时间字符串。`now` 默认是当前时间;header 用 `TimelineView` 驱动时
    /// 把 timeline 提供的 `context.date` 传进来,避免和 `Date()` 真实时间细微偏差。
    static func relativeAge(from date: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h" }
        return "\(hours / 24)d"
    }
}

// MARK: - ProviderAccountsHeader

/// "CODEX ACCOUNTS        all · 3" strip above a provider with several cards.
struct ProviderAccountsHeader: View {
    let title: String
    let chineseTitle: String
    let count: Int

    var body: some View {
        HStack {
            Text(tr(title, chineseTitle))
                .font(.system(size: 9.5, weight: .semibold))
                .kerning(0.3)
                .foregroundStyle(.tertiary)

            Spacer()

            Text("all · \(count)")
                .font(.system(size: 9.5, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.quaternary)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 2)
    }
}

// MARK: - ServiceBlockView
//
// One account card, kept to one text line per element so a popover with several
// accounts stays short: header (tile, name, identity, state note, plan chip, status
// dot), one lane per limit (title, detail, pace tag, remaining, reset + bar), a
// one-line cost summary, action row (Dashboard / Status / Terminal / Set default),
// error line.

struct ServiceBlockView: View {
    struct Usage {
        var today: UsageTotals?
        var week: UsageTotals?
        var month: UsageTotals?
        /// Cursor only has remote cost, no token counts.
        var showsTokens: Bool
    }

    let app: QuotaApp
    let title: String
    let subtitle: String
    let tint: Color
    let logoName: String
    let fallback: String
    let state: PrimaryQuotaState
    let error: String?
    let usage: Usage?
    let serviceStatus: ServiceStatus?
    let planBadge: String?
    let dashboardURL: URL?
    let statusPageURL: URL?
    /// Set for ccpm profile cards; drives the Terminal / Set default actions.
    var ccpmAccount: CCPMAccount? = nil
    /// When set the card has no quota lanes and shows this reason instead.
    var unavailableReason: String? = nil
    /// Called after a ccpm action changed profiles (set-default) so the caller rediscovers.
    var onProfilesChanged: () -> Void = {}

    @State private var actionError: String?

    private var snapshot: QuotaSnapshot? { state.snapshot }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            headerRow

            if let unavailableReason {
                Text(unavailableReason)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } else if isUnlimited {
                unlimitedRow
            } else {
                ForEach(lanes) { lane in
                    laneSection(lane)
                }
            }

            if let usage {
                usageSection(usage)
            }

            actionRow

            if let actionError {
                Text(actionError)
                    .font(.system(size: 10.5))
                    .foregroundStyle(quotaPaceAheadColor)
                    .lineLimit(2)
            }
            if let message = shortError(error) {
                HStack(alignment: .top, spacing: 5) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                    Text(message)
                        .font(.system(size: 11))
                        .lineLimit(2)
                }
                .foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(unavailableReason == nil ? 1 : 0.75)
    }

    // MARK: Header

    private var headerRow: some View {
        HStack(alignment: .center, spacing: 9) {
            ServiceTile(logoName: logoName, fallback: fallback, tint: tint)

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .kerning(-0.1)
                    .lineLimit(1)
                    .layoutPriority(1)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary.opacity(0.75))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 6)

            // The popover header already shows the global refresh age; a card only
            // calls out its own state when it differs from "fresh API data".
            if let note = headerNote {
                Text(note)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            if let planBadge {
                Text(planBadge)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.12), in: Capsule())
            }

            if let status = serviceStatus, status.indicator != .unknown {
                Circle()
                    .fill(status.indicator.dotColor)
                    .frame(width: 6, height: 6)
                    .help(serviceStatusTooltip(status))
            }
        }
    }

    private var headerNote: String? {
        if state.refresh.inFlight { return tr("Refreshing…", "刷新中…") }
        if unavailableReason != nil { return tr("Not monitored", "未监控") }
        if snapshot == nil, error != nil || state.error != nil {
            return tr("Refresh failed", "刷新失败")
        }
        if let source = state.source, source != .api { return source.displayName }
        return nil
    }

    private func serviceStatusTooltip(_ status: ServiceStatus) -> String {
        let trimmed = status.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let head = trimmed.isEmpty ? status.indicator.label : trimmed
        guard let updatedAt = status.updatedAt else { return head }
        let age = PopoverRootView.relativeAge(from: updatedAt)
        return tr("\(head) · updated \(age) ago", "\(head) · \(age) 前更新")
    }

    // MARK: Lanes

    private struct Lane: Identifiable {
        let id: String
        let limit: QuotaLimit?
    }

    /// Primary, secondary, auxiliary and model limits, deduplicated by id; a single
    /// placeholder lane while nothing has been fetched yet.
    private var lanes: [Lane] {
        guard let snapshot else { return [Lane(id: "placeholder", limit: nil)] }
        let candidates = [snapshot.primaryLimit, snapshot.secondaryLimit].compactMap { $0 }
            + snapshot.auxiliaryLimits
            + snapshot.modelLimits
        let unique = candidates.reduce(into: [QuotaLimit]()) { result, limit in
            if !result.contains(where: { $0.id == limit.id }) {
                result.append(limit)
            }
        }
        if unique.isEmpty { return [Lane(id: "placeholder", limit: nil)] }
        return unique.map { Lane(id: $0.id, limit: $0) }
    }

    private func laneSection(_ lane: Lane) -> some View {
        let window = lane.limit?.window
        let color = laneColor(window)
        let pace = lane.limit.flatMap { QuotaPace.compute(limit: $0) }
        return VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(lane.limit.map(laneTitle) ?? tr("Quota", "额度"))
                    .font(.system(size: 11.5, weight: .semibold))
                    .lineLimit(1)
                    .layoutPriority(1)
                if let detail = window?.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 10.5))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 6)
                if let pace {
                    Text(paceTag(pace))
                        .font(.system(size: 10.5, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(pace.isAhead ? quotaPaceAheadColor : .secondary)
                        .help(paceText(pace))
                        .layoutPriority(1)
                }
                Text(remainingText(window))
                    .font(.system(size: 11.5, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(color)
                    .layoutPriority(2)
                laneResetStatus(lane.limit)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .layoutPriority(2)
            }

            ProgressBar(value: (window?.remainingPercent ?? 0) / 100, tint: color, height: 5)
        }
    }

    @ViewBuilder
    private func laneResetStatus(_ limit: QuotaLimit?) -> some View {
        if let limit,
           limit.kind == .modelWeekly,
           limit.window.usedPercent == 0,
           limit.window.resetsAt == nil
        {
            Text(tr("Unused", "尚未使用"))
        } else {
            ResetHintText(resetsAt: limit?.window.resetsAt)
        }
    }

    private var unlimitedRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("∞")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(tr("Unlimited", "不限额度"))
                .font(.system(size: 12, weight: .semibold))
            Spacer(minLength: 8)
            ResetHintText(resetsAt: snapshot?.primaryLimit?.window.resetsAt)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    /// Antigravity / Cursor name their windows officially (Gemini 5H, Auto, ...); the
    /// rest fall back to the window kind. Model and custom lanes always use their name.
    private func laneTitle(_ limit: QuotaLimit) -> String {
        let name = limit.displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let officiallyNamed = app == .antigravity || app == .cursor
        switch limit.kind {
        case .fiveHour:
            if officiallyNamed, !name.isEmpty { return name }
            return tr("Session · 5h", "5 小时")
        case .weekly:
            if officiallyNamed, !name.isEmpty { return name }
            return tr("Weekly", "周额度")
        case .modelWeekly:
            if name.isEmpty { return tr("Weekly", "周额度") }
            return tr("\(name) · weekly", "\(name) · 周")
        case .unknown:
            return name.isEmpty ? tr("Current window", "当前窗口") : name
        }
    }

    private func remainingText(_ window: QuotaWindow?) -> String {
        guard let window else { return "--%" }
        let left = Int(window.remainingPercent.rounded())
        return tr("\(left)% left", "剩余 \(left)%")
    }

    /// "▲ +6%" / "▼ -20%" / "● on track"; the full sentence lives in the tooltip.
    private func paceTag(_ pace: QuotaPace) -> String {
        let delta = Int(pace.deltaPercent.rounded())
        if delta > 0 { return "▲ +\(delta)%" }
        if delta < 0 { return "▼ \(delta)%" }
        return tr("● on track", "● 正常")
    }

    private func paceText(_ pace: QuotaPace) -> String {
        let delta = Int(pace.deltaPercent.rounded())
        let head: String
        if delta > 0 {
            head = tr("Pace: ahead +\(delta)%", "节奏：超前 +\(delta)%")
        } else if delta < 0 {
            head = tr("Pace: behind \(delta)%", "节奏：落后 \(delta)%")
        } else {
            head = tr("Pace: on track", "节奏：正常")
        }
        if let runsOutAt = pace.runsOutAt {
            let compact = formatResetCompact(runsOutAt)
            return "\(head) · " + tr("runs out in \(compact)", "预计 \(compact) 后耗尽")
        }
        return "\(head) · " + tr("lasts to reset", "可撑到重置")
    }

    private func laneColor(_ window: QuotaWindow?) -> Color {
        guard let window else { return .secondary }
        return statusColor(remainingPercent: window.remainingPercent, tint: tint)
    }

    private var isUnlimited: Bool {
        snapshot?.isUnlimited == true
    }

    // MARK: Local usage

    private func usageSection(_ usage: Usage) -> some View {
        HStack(spacing: 0) {
            usagePart(tr("Today", "今日"), usage.today)
            usageSeparator
            usagePart(tr("Week", "本周"), usage.week)
            usageSeparator
            usagePart(tr("30d", "30 天"), usage.month)
            Spacer(minLength: 0)
        }
        .font(.system(size: 11))
        .lineLimit(1)
        .help(usage.showsTokens ? tokensTooltip(usage) : "")
    }

    private var usageSeparator: some View {
        Text(" · ")
            .foregroundStyle(.quaternary)
    }

    private func usagePart(_ label: String, _ totals: UsageTotals?) -> some View {
        HStack(spacing: 0) {
            Text("\(label) ")
                .foregroundStyle(.secondary)
            Text(totals.map { StatsFormatter.cost($0.costUSD) } ?? "—")
                .foregroundStyle(.primary)
                .monospacedDigit()
        }
    }

    private func tokensTooltip(_ usage: Usage) -> String {
        func line(_ label: String, _ totals: UsageTotals?) -> String {
            guard let totals else { return "\(label): —" }
            return "\(label): \(StatsFormatter.compactToken(totals.totalTokens)) tokens"
        }
        return [
            line(tr("Today", "今日"), usage.today),
            line(tr("This week", "本周"), usage.week),
            line(tr("Last 30 days", "最近 30 天"), usage.month),
        ].joined(separator: "\n")
    }

    // MARK: Actions

    private var actionRow: some View {
        let actions = availableActions
        return HStack(spacing: 0) {
            ForEach(Array(actions.enumerated()), id: \.offset) { index, action in
                if index > 0 {
                    Text(" · ")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.quaternary)
                }
                Button(action: action.perform) {
                    Text(action.title)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
            }
            Spacer(minLength: 0)
        }
    }

    private struct CardAction {
        let title: String
        let perform: () -> Void
    }

    private var availableActions: [CardAction] {
        var actions: [CardAction] = []
        if let dashboardURL {
            actions.append(CardAction(title: tr("Dashboard", "用量面板")) {
                NSWorkspace.shared.open(dashboardURL)
            })
        }
        if let statusPageURL {
            actions.append(CardAction(title: tr("Status", "状态页")) {
                NSWorkspace.shared.open(statusPageURL)
            })
        }
        // ccpm launches Claude Code (and the compatible providers); Codex profiles
        // only carry credentials, so the terminal actions do not apply to them.
        if let account = ccpmAccount, account.app != .codex {
            let profile = account.profile.name
            actions.append(CardAction(title: tr("Terminal", "终端")) {
                actionError = nil
                CCPMCommand.openInTerminal(profile: profile)
            })
            if !account.profile.isDefault {
                actions.append(CardAction(title: tr("Set default", "设为默认")) {
                    actionError = nil
                    if CCPMCommand.setDefault(profile: profile) {
                        onProfilesChanged()
                    } else {
                        actionError = tr("ccpm set-default failed", "ccpm set-default 失败")
                    }
                })
            }
        }
        return actions
    }

    // MARK: Formatting

    /// "max_20x" → "Max 20x"; nil / empty → nil.
    static func formatPlan(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        return raw.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private func shortError(_ error: String?) -> String? {
        guard let error, !error.isEmpty else { return nil }
        let oneLine = error.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if oneLine.count <= 110 { return oneLine }
        return String(oneLine.prefix(107)) + "..."
    }
}

/// "resets in 4h 37m" that ticks every minute and flips to the absolute time on hover.
struct ResetHintText: View {
    let resetsAt: Date?
    @State private var hovering = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            Text(hovering
                 ? formatResetAltCompact(resetsAt, now: context.date)
                 : formatResetHint(resetsAt, now: context.date))
                .monospacedDigit()
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }
    }
}
