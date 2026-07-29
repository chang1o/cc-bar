import SwiftUI
import AppKit

// MARK: - PopoverRootView
//
// 见 docs/04-界面布局.md §1。
// 结构:Header(标题 + 状态点 + 统计/刷新/设置 三个一级图标 + ⋯ kebab) /
//      Codex block(tile + 服务名/plan + reset / 56pt 环 + weekly 条 + stats 行) /
//      Claude block(同上)。footer 已合并到 header,不再单独存在。

struct PopoverRootView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow
    @State private var refreshRotation: Double = 0

    var body: some View {
        VStack(spacing: 0) {
            header

            if let risk = quotaRisk {
                riskBanner(risk)
            }

            Divider()

            ScrollView {
                content
            }
            .frame(height: contentHeight)
        }
        .frame(width: 340)
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

            Button(action: toggleMenuBarQuotaWindow) {
                Text(menuBarQuotaWindow.shortLabel)
                    .font(.system(size: 10.5, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(PopoverIconButtonStyle())
            .help(menuBarQuotaWindow == .fiveHour
                ? tr("Show weekly quota", "显示周额度")
                : tr("Show 5-hour quota", "显示 5 小时额度"))

            Button(action: refresh) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(refreshRotation))
                    .animation(.easeInOut(duration: 0.7), value: refreshRotation)
            }
            .buttonStyle(PopoverIconButtonStyle())
            // 不加 disabled:按钮永远可点,每次点击都有图标转动的视觉反馈;
            // AppState.refreshNow() 内部已经做了 in-flight 去重,不会重复发请求。
            .help(tr("Refresh now", "立即刷新"))

            Button { activateAndOpenMain(tab: .stats) } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chart.bar.xaxis")
                        .font(.system(size: 12.5, weight: .medium))
                    Text(tr("Stats", "统计"))
                        .font(.system(size: 10.5, weight: .semibold))
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(PopoverTextButtonStyle(width: 54))
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
        let settings = SettingsStore.shared
        let importedCodexLatest = settings.showCodex
            ? appState.importedCodexRefreshStates.values.compactMap(\.lastSuccessAt).max()
            : nil
        let ccpmCodexLatest = settings.showCodex
            ? appState.ccpmCodexRefreshStates.values.compactMap(\.lastSuccessAt).max()
            : nil
        let ccpmClaudeLatest = settings.showClaude
            ? appState.ccpmClaudeRefreshStates.values.compactMap(\.lastSuccessAt).max()
            : nil
        let latest = [
            settings.showCodex ? appState.codexRefreshState.lastSuccessAt : nil,
            settings.showClaude ? appState.claudeRefreshState.lastSuccessAt : nil,
            importedCodexLatest,
            ccpmCodexLatest,
            ccpmClaudeLatest
        ].compactMap { $0 }.max()

        if let latest {
            let age = Self.relativeAge(from: latest, now: now)
            return tr("refreshed \(age) ago", "\(age) 前已刷新")
        }
        if (settings.showCodex && appState.codexQuotaError != nil)
            || (settings.showCodex && appState.importedCodexErrors.values.contains(where: { !$0.isEmpty }))
            || (settings.showCodex && appState.ccpmCodexErrors.values.contains(where: { !$0.isEmpty }))
            || (settings.showClaude && appState.claudeQuotaError != nil)
            || (settings.showClaude && appState.ccpmClaudeErrors.values.contains(where: { !$0.isEmpty })) {
            return tr("refresh failed", "刷新失败")
        }
        return tr("waiting…", "等待数据")
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        let showCodex = SettingsStore.shared.showCodex
        let showClaude = SettingsStore.shared.showClaude
        let hasAdditionalCodex = hasAdditionalCodexAccounts
        let hasCCPMClaude = appState.hasCCPMClaudeProfiles

        if !showCodex && !showClaude {
            VStack(spacing: 6) {
                Text(tr("No services enabled", "未启用任何服务"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(tr("Enable a service in Settings → Accounts", "到「设置 → 账号」开启"))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
        } else {
            VStack(spacing: 0) {
                if showCodex {
                    if hasAdditionalCodex {
                        CodexAccountsSection(primaryWindow: menuBarQuotaWindow)
                    } else {
                        ServiceBlockView(
                            title: "Codex",
                            subtitle: codexSubtitle,
                            tint: .codexAccent,
                            logoName: "codex",
                            fallback: "C",
                            primaryWindow: menuBarQuotaWindow,
                            snapshot: appState.codexQuota,
                            error: appState.codexQuotaError,
                            weekSpend: weekSpend(for: .codex),
                            todayCost: appState.codexTodayCost,
                            serviceStatus: SettingsStore.shared.showServiceStatus ? appState.codexServiceStatus : nil
                        )
                    }
                }

                if showClaude && showCodex {
                    Divider().padding(.horizontal, 16)
                }
                if showClaude {
                    if hasCCPMClaude {
                        ClaudeAccountsSection(primaryWindow: menuBarQuotaWindow)
                    } else {
                        ServiceBlockView(
                            title: "Claude Code",
                            subtitle: claudeSubtitle,
                            tint: .claudeAccent,
                            logoName: "claude",
                            fallback: "K",
                            primaryWindow: menuBarQuotaWindow,
                            snapshot: appState.claudeQuota,
                            error: appState.claudeQuotaError,
                            weekSpend: weekSpend(for: .claude),
                            todayCost: appState.claudeTodayCost,
                            serviceStatus: SettingsStore.shared.showServiceStatus ? appState.claudeServiceStatus : nil
                        )
                    }
                }
            }
        }
    }

    private var codexSubtitle: String {
        let privacy = SettingsStore.shared.privacyMode
        var parts: [String] = []
        if !privacy, let email = appState.codexAccount?.email, !email.isEmpty {
            parts.append(email)
        }
        if let plan = appState.codexAccount?.planType, !plan.isEmpty {
            parts.append(plan.capitalized)
        }
        if parts.isEmpty { parts.append("OpenAI") }
        return parts.joined(separator: " · ")
    }

    private var claudeSubtitle: String {
        let privacy = SettingsStore.shared.privacyMode
        var parts: [String] = []
        if !privacy, let email = appState.claudeAccount?.email, !email.isEmpty {
            parts.append(email)
        }
        if let plan = appState.claudeAccount?.subscriptionType, !plan.isEmpty {
            parts.append(plan.capitalized)
        }
        if parts.isEmpty { parts.append("Anthropic") }
        return parts.joined(separator: " · ")
    }

    private func weekSpend(for app: UsageApp) -> Decimal {
        let (from, to) = Self.weekBounds()
        let totals = appState.usageService.aggregator.totals(app: app, from: from, to: to)
        return totals.costUSD
    }

    private var menuBarQuotaWindow: MenuBarWindowChoice {
        SettingsStore.shared.menuBarWindow
    }

    private var hasAdditionalCodexAccounts: Bool {
        appState.importedCodexAccounts.contains(where: \.visibleInPopover)
            || appState.hasCCPMCodexProfiles
    }

    private var maxContentHeight: CGFloat {
        let available = NSScreen.main?.visibleFrame.height ?? 900
        return min(680, max(320, available * 0.78))
    }

    private var contentHeight: CGFloat {
        min(maxContentHeight, estimatedContentHeight)
    }

    private var estimatedContentHeight: CGFloat {
        let settings = SettingsStore.shared
        guard settings.showCodex || settings.showClaude else {
            return Self.emptyContentHeight
        }

        var height: CGFloat = 0
        var hasSection = false

        func appendSection(_ sectionHeight: CGFloat) {
            if hasSection { height += Self.dividerHeight }
            height += sectionHeight
            hasSection = true
        }

        if settings.showCodex {
            if hasAdditionalCodexAccounts {
                let count = monitoredCodexBlockCount
                appendSection(Self.accountsSectionHeaderHeight
                    + CGFloat(count) * Self.serviceBlockHeight
                    + CGFloat(max(0, count - 1)) * Self.dividerHeight)
            } else {
                appendSection(Self.serviceBlockHeight)
            }
        }

        if settings.showClaude {
            if appState.hasCCPMClaudeProfiles {
                let count = monitoredClaudeBlockCount
                appendSection(Self.accountsSectionHeaderHeight
                    + CGFloat(count) * Self.serviceBlockHeight
                    + CGFloat(max(0, count - 1)) * Self.dividerHeight)
            } else {
                appendSection(Self.serviceBlockHeight)
            }
        }

        return max(Self.emptyContentHeight, height)
    }

    private var monitoredCodexBlockCount: Int {
        var count = appState.importedCodexAccounts.filter(\.visibleInPopover).count
            + appState.ccpmCodexProfilesForMonitoring.count
        if appState.codexAccount != nil
            || appState.codexQuota != nil
            || appState.codexQuotaError != nil
            || appState.codexRefreshState.inFlight {
            count += 1
        }
        return max(1, count)
    }

    private var monitoredClaudeBlockCount: Int {
        var count = appState.ccpmClaudeProfilesForMonitoring.count
        if appState.claudeAccount != nil
            || appState.claudeQuota != nil
            || appState.claudeQuotaError != nil
            || appState.claudeRefreshState.inFlight {
            count += 1
        }
        return max(1, count)
    }

    private static let emptyContentHeight: CGFloat = 96
    private static let serviceBlockHeight: CGFloat = 142
    private static let accountsSectionHeaderHeight: CGFloat = 28
    private static let dividerHeight: CGFloat = 1

    // MARK: Quota risk summary

    private var quotaRisk: QuotaRiskItem? {
        let settings = SettingsStore.shared
        var candidates: [QuotaRiskItem] = []

        if settings.showCodex {
            appendRiskCandidates(
                title: "Codex",
                snapshot: appState.codexQuota,
                tint: .codexAccent,
                to: &candidates
            )

            for (idx, account) in appState.importedCodexAccounts.filter(\.visibleInPopover).enumerated() {
                appendRiskCandidates(
                    title: importedCodexRiskTitle(account, index: idx),
                    snapshot: appState.importedCodexQuota(for: account),
                    tint: .codexAccent,
                    to: &candidates
                )
            }

            for (idx, profile) in appState.ccpmCodexProfilesForMonitoring.enumerated() {
                appendRiskCandidates(
                    title: ccpmCodexRiskTitle(profile, index: idx),
                    snapshot: appState.ccpmCodexQuota(for: profile),
                    tint: .codexAccent,
                    to: &candidates
                )
            }
        }

        if settings.showClaude {
            appendRiskCandidates(
                title: tr("Claude · Default", "Claude · 默认"),
                snapshot: appState.claudeQuota,
                tint: .claudeAccent,
                to: &candidates
            )

            for (idx, profile) in appState.ccpmClaudeProfilesForMonitoring.enumerated() {
                appendRiskCandidates(
                    title: ccpmClaudeRiskTitle(profile, index: idx),
                    snapshot: appState.ccpmClaudeQuota(for: profile),
                    tint: .claudeAccent,
                    to: &candidates
                )
            }
        }

        return candidates
            .filter { $0.remainingPercent <= 20 }
            .min { lhs, rhs in lhs.remainingPercent < rhs.remainingPercent }
    }

    private func appendRiskCandidates(
        title: String,
        snapshot: QuotaSnapshot?,
        tint: Color,
        to candidates: inout [QuotaRiskItem]
    ) {
        if let fiveHour = snapshot?.fiveHour {
            candidates.append(QuotaRiskItem(title: title, windowLabel: "5H", window: fiveHour, tint: tint))
        }
        if let weekly = snapshot?.weekly {
            candidates.append(QuotaRiskItem(title: title, windowLabel: "WK", window: weekly, tint: tint))
        }
    }

    private func importedCodexRiskTitle(_ account: ImportedCodexAccount, index: Int) -> String {
        if SettingsStore.shared.privacyMode {
            return tr("Codex · Account \(index + 1)", "Codex · 账号 \(index + 1)")
        }
        if !account.alias.isEmpty { return "Codex · \(account.alias)" }
        if let email = account.email, !email.isEmpty {
            return "Codex · \(emailUsername(email))"
        }
        return "Codex · \(account.id)"
    }

    private func ccpmCodexRiskTitle(_ profile: CCPMCodexProfile, index: Int) -> String {
        if SettingsStore.shared.privacyMode {
            let offset = appState.importedCodexAccounts.filter(\.visibleInPopover).count
            return tr("Codex · Account \(offset + index + 1)", "Codex · 账号 \(offset + index + 1)")
        }
        if let email = profile.email, !email.isEmpty {
            return "Codex · \(emailUsername(email))"
        }
        return "Codex · \(profile.name)"
    }

    private func ccpmClaudeRiskTitle(_ profile: CCPMClaudeProfile, index: Int) -> String {
        if SettingsStore.shared.privacyMode {
            return tr("Claude · Profile \(index + 1)", "Claude · 账号 \(index + 1)")
        }
        if let displayName = profile.displayName, !displayName.isEmpty {
            return "Claude · \(displayName)"
        }
        if let email = profile.email, !email.isEmpty {
            return "Claude · \(emailUsername(email))"
        }
        return "Claude · \(profile.name)"
    }

    private func emailUsername(_ email: String) -> String {
        email.components(separatedBy: "@").first ?? email
    }

    private func riskBanner(_ risk: QuotaRiskItem) -> some View {
        let color = statusColor(remainingPercent: risk.remainingPercent, tint: risk.tint)
        return HStack(spacing: 8) {
            Image(systemName: risk.remainingPercent <= 0 ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(color)

            VStack(alignment: .leading, spacing: 1) {
                Text(tr("Quota risk", "额度风险"))
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(color)
                    .textCase(.uppercase)
                Text("\(risk.title) · \(risk.windowLabel)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 1) {
                Text("\(Int(risk.remainingPercent.rounded()))%")
                    .font(.system(size: 14, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(color)
                Text(formatResetCompact(risk.window.resetsAt))
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(color.opacity(0.10))
    }

    // MARK: Header state (live / stale / offline)

    private var headerState: CCRefreshState? {
        let settings = SettingsStore.shared
        let codex = appState.codexRefreshState
        let claude = appState.claudeRefreshState
        let codexLast = settings.showCodex ? codex.lastSuccessAt : nil
        let claudeLast = settings.showClaude ? claude.lastSuccessAt : nil
        let importedCodexLast = settings.showCodex
            ? appState.importedCodexRefreshStates.values.compactMap(\.lastSuccessAt).max()
            : nil
        let ccpmCodexLast = settings.showCodex
            ? appState.ccpmCodexRefreshStates.values.compactMap(\.lastSuccessAt).max()
            : nil
        let ccpmClaudeLast = settings.showClaude
            ? appState.ccpmClaudeRefreshStates.values.compactMap(\.lastSuccessAt).max()
            : nil
        let latest = [
            codexLast,
            claudeLast,
            importedCodexLast,
            ccpmCodexLast,
            ccpmClaudeLast
        ].compactMap { $0 }.max()
        let hasError = (settings.showCodex && codex.lastError != nil)
            || (settings.showCodex && appState.importedCodexRefreshStates.values.contains { $0.lastError != nil })
            || (settings.showCodex && appState.ccpmCodexRefreshStates.values.contains { $0.lastError != nil })
            || (settings.showClaude && claude.lastError != nil)
            || (settings.showClaude && appState.ccpmClaudeRefreshStates.values.contains { $0.lastError != nil })

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
    private func activateAndOpenMain(tab: MainTab) {
        appState.mainTab = tab
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "main")
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 120_000_000)
            appState.mainTab = tab
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows
                .first { $0.title == "CCBar" }
                .map { window in
                    window.makeKeyAndOrderFront(nil)
                    window.orderFrontRegardless()
                }
        }
    }

    // MARK: Refresh

    /// 用户点刷新按钮的处理:
    /// - **永远**先转一圈图标(无论内部状态),给用户即时视觉反馈
    /// - 启动一个非阻塞 Task 去做真正的刷新工作;UI 不等
    /// - 真正的去重 / 协调放在 `AppState.refreshNow()` 内部,这里只负责"启动"
    /// - 数据更新通过 @Observable 自动驱动 UI 刷新,不需要在这里 await 结果
    private func refresh() {
        refreshRotation += 360
        Task { await appState.refreshNow() }
    }

    private func toggleMenuBarQuotaWindow() {
        SettingsStore.shared.menuBarWindow = SettingsStore.shared.menuBarWindow.toggledForMenuBar
        FloatingPanelController.shared.sync()
    }

    // MARK: Helpers

    private static func weekBounds(now: Date = Date()) -> (Date, Date) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        cal.firstWeekday = 2
        let startOfToday = cal.startOfDay(for: now)
        let startOfTomorrow = cal.date(byAdding: .day, value: 1, to: startOfToday) ?? startOfToday
        let comps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)
        let weekStart = cal.date(from: comps) ?? startOfToday
        return (weekStart, startOfTomorrow)
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

private struct QuotaRiskItem {
    let title: String
    let windowLabel: String
    let window: QuotaWindow
    let tint: Color

    var remainingPercent: Double {
        window.remainingPercent
    }
}

// MARK: - ServiceBlockView

struct ServiceAccountsSectionHeader: View {
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

struct ServiceBlockView: View {
    let title: String
    let subtitle: String
    let tint: Color
    let logoName: String
    let fallback: String
    let primaryWindow: MenuBarWindowChoice
    let snapshot: QuotaSnapshot?
    let error: String?
    let weekSpend: Decimal?
    let todayCost: Decimal?
    let serviceStatus: ServiceStatus?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerRow
            bodyRow
            secondaryRow
            if let message = shortError(error) {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var headerRow: some View {
        HStack(spacing: 9) {
            ServiceTile(logoName: logoName, fallback: fallback, tint: tint)

            (
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .kerning(-0.1)
                    .foregroundColor(.primary)
                + Text("   ")
                + Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary.opacity(0.75))
            )
            .lineLimit(1)
            .truncationMode(.tail)

            Spacer(minLength: 0)

            if let status = serviceStatus, status.indicator != .unknown {
                Circle()
                    .fill(status.indicator.dotColor)
                    .frame(width: 6, height: 6)
                    .help(serviceStatusTooltip(status))
            }
        }
    }

    private func serviceStatusTooltip(_ status: ServiceStatus) -> String {
        let trimmed = status.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let head = trimmed.isEmpty ? status.indicator.label : trimmed
        guard let updatedAt = status.updatedAt else { return head }
        let age = PopoverRootView.relativeAge(from: updatedAt)
        return tr("\(head) · updated \(age) ago", "\(head) · \(age) 前更新")
    }

    private var bodyRow: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .center, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text(primaryValueText)
                        .font(.system(size: 32, weight: .semibold))
                        .monospacedDigit()
                        .kerning(-0.8)
                        .foregroundStyle(primaryColor)
                        .lineLimit(1)
                    Text("%")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(primaryColor.opacity(0.75))
                }
                .fixedSize()

                Text(primaryLabel)
                    .font(.system(size: 9, weight: .semibold))
                    .kerning(0.5)
                    .foregroundStyle(.quaternary)
            }

            VStack(alignment: .leading, spacing: 8) {
                ProgressBar(value: primaryRemaining / 100, tint: primaryColor, height: 7)

                VStack(spacing: 1) {
                    HStack(spacing: 0) {
                        ResetTimeText(resetsAt: primaryQuota?.resetsAt)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        Spacer(minLength: 8)

                        HStack(spacing: 10) {
                            statInline(value: formatCostInt(todayCost), english: "today", chinese: "今日")
                            statInline(value: formatCostInt(weekSpend), english: "this week", chinese: "本周")
                        }
                    }

                    HStack(spacing: 0) {
                        BilingualInline(english: "reset", chinese: "重置")
                            .font(.system(size: 9.5))
                            .foregroundStyle(.quaternary)

                        Spacer(minLength: 0)

                        BilingualInline(english: "cost", chinese: "花费")
                            .font(.system(size: 9.5))
                            .foregroundStyle(.quaternary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var secondaryRow: some View {
        HStack(spacing: 10) {
            Text(secondaryShortLabel)
                .font(.system(size: 9, weight: .semibold))
                .kerning(0.6)
                .foregroundStyle(.quaternary)
                .frame(width: 36, alignment: .leading)

            ProgressBar(value: secondaryRemaining / 100, tint: secondaryColor, height: 2.5)

            Text(secondaryPercentText)
                .font(.system(size: 10.5, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(secondaryColor)

            ResetTimeText(resetsAt: secondaryQuota?.resetsAt)
                .font(.system(size: 10.5))
                .foregroundStyle(.quaternary)
        }
    }

    private func statInline(value: String, english: String, chinese: String) -> some View {
        HStack(spacing: 4) {
            BilingualInline(english: english, chinese: chinese)
                .font(.system(size: 10))
                .foregroundStyle(.quaternary)
            Text(value)
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.primary)
        }
    }

    // MARK: Derived data

    private var primaryQuota: QuotaWindow? {
        switch primaryWindow {
        case .fiveHour, .both: return snapshot?.fiveHour
        case .weekly: return snapshot?.weekly
        }
    }

    private var secondaryQuota: QuotaWindow? {
        switch primaryWindow {
        case .fiveHour, .both: return snapshot?.weekly
        case .weekly: return snapshot?.fiveHour
        }
    }

    private var primaryRemaining: Double {
        primaryQuota?.remainingPercent ?? 0
    }

    private var secondaryRemaining: Double {
        secondaryQuota?.remainingPercent ?? 0
    }

    private var primaryColor: Color {
        guard primaryQuota != nil else { return .secondary }
        return statusColor(remainingPercent: primaryRemaining, tint: tint)
    }

    private var secondaryColor: Color {
        guard secondaryQuota != nil else { return .secondary }
        return statusColor(remainingPercent: secondaryRemaining, tint: tint)
    }

    private var primaryValueText: String {
        guard let window = primaryQuota else { return "--" }
        return "\(Int(window.remainingPercent.rounded()))"
    }

    private var secondaryPercentText: String {
        guard let window = secondaryQuota else { return "--%" }
        return "\(Int(window.remainingPercent.rounded()))%"
    }

    private var primaryLabel: String {
        switch primaryWindow {
        case .fiveHour, .both: return "5-HOUR · 五小时"
        case .weekly: return "WEEKLY · 周额度"
        }
    }

    private var secondaryShortLabel: String {
        switch primaryWindow {
        case .fiveHour, .both: return "WK"
        case .weekly: return "5H"
        }
    }

    /// 取整美元金额:`<$1` 用于 0 ~ 0.99,`$0` 仅在 nil/0 时显示。
    private func formatCostInt(_ value: Decimal?) -> String {
        guard let value else { return "—" }
        let d = NSDecimalNumber(decimal: value).doubleValue
        if d <= 0 { return "$0" }
        if d < 1 { return "<$1" }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.maximumFractionDigits = 0
        formatter.minimumFractionDigits = 0
        return "$\(formatter.string(from: NSDecimalNumber(decimal: value)) ?? "0")"
    }

    private func shortError(_ error: String?) -> String? {
        guard let error, !error.isEmpty else { return nil }
        let oneLine = error.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if oneLine.count <= 110 { return oneLine }
        return String(oneLine.prefix(107)) + "..."
    }
}
