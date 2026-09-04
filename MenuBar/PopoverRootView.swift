import SwiftUI
import AppKit

// MARK: - PopoverRootView
//
// Header (title + refresh age + state dot + lane toggle + refresh / stats / settings / quit)
// + optional risk banner + one `ProviderSection` per visible provider.

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

                // Re-render every second so "refreshed Xs ago" ticks; costs nothing while hidden.
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
                Text(laneToggleLabel)
                    .font(.system(size: 10.5, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(PopoverIconButtonStyle())
            .help(menuBarQuotaWindow == .primary
                ? tr("Show secondary window", "显示副窗口额度")
                : tr("Show primary window", "显示主窗口额度"))

            Button(action: refresh) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(refreshRotation))
                    .animation(.easeInOut(duration: 0.7), value: refreshRotation)
            }
            .buttonStyle(PopoverIconButtonStyle())
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

    /// Lane toggle shows the label of the lane that is currently the headline
    /// for the first visible provider (5H / WK for most, MO / WK for Ollama).
    private var laneToggleLabel: String {
        let provider = appState.visibleProviders.first ?? .codex
        let descriptor = provider.descriptor
        switch menuBarQuotaWindow {
        case .primary: return descriptor.primaryKind.shortLabel
        case .secondary: return descriptor.secondaryKind?.shortLabel ?? descriptor.primaryKind.shortLabel
        case .both: return "\(descriptor.primaryKind.shortLabel)/\(descriptor.secondaryKind?.shortLabel ?? "")"
        }
    }

    private func headerSubtitle(now: Date) -> String {
        if let latest = appState.latestVisibleSuccess {
            let age = Self.relativeAge(from: latest, now: now)
            return tr("refreshed \(age) ago", "\(age) 前已刷新")
        }
        if appState.hasVisibleError {
            return tr("refresh failed", "刷新失败")
        }
        return tr("waiting…", "等待数据")
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        let providers = appState.visibleProviders
        if providers.isEmpty {
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
                ForEach(Array(providers.enumerated()), id: \.element) { index, provider in
                    if index > 0 {
                        Divider().padding(.horizontal, 16)
                    }
                    ProviderSection(provider: provider)
                }
            }
        }
    }

    private var menuBarQuotaWindow: MenuBarWindowChoice {
        SettingsStore.shared.menuBarWindow
    }

    // MARK: Height

    private var maxContentHeight: CGFloat {
        let available = NSScreen.main?.visibleFrame.height ?? 900
        return min(680, max(320, available * 0.78))
    }

    private var contentHeight: CGFloat {
        min(maxContentHeight, estimatedContentHeight)
    }

    private var estimatedContentHeight: CGFloat {
        let providers = appState.visibleProviders
        guard !providers.isEmpty else { return Self.emptyContentHeight }

        var height: CGFloat = 0
        for (index, provider) in providers.enumerated() {
            if index > 0 { height += Self.dividerHeight }
            let accounts = appState.accounts(for: provider)
            if accounts.count > 1 { height += Self.accountsSectionHeaderHeight }
            for (position, account) in accounts.enumerated() {
                if position > 0 { height += Self.dividerHeight }
                height += cardHeight(account)
            }
        }
        return max(Self.emptyContentHeight, height)
    }

    private func cardHeight(_ account: MonitoredAccount) -> CGFloat {
        let state = appState.quotaState(for: account)
        var height = Self.cardBaseHeight
        let lanes: [QuotaWindow?]
        if let snapshot = state.snapshot {
            lanes = snapshot.allWindows
        } else {
            lanes = Array(repeating: nil, count: account.descriptor.secondaryKind == nil ? 1 : 2)
        }
        for lane in lanes {
            height += Self.laneHeight
            if let lane, QuotaPace.compute(window: lane) != nil { height += Self.paceLineHeight }
        }
        if !account.usageRoots.isEmpty { height += Self.costSectionHeight }
        height += Self.actionRowHeight
        if state.error != nil { height += Self.errorLineHeight }
        return height
    }

    private static let emptyContentHeight: CGFloat = 96
    private static let cardBaseHeight: CGFloat = 78
    private static let laneHeight: CGFloat = 58
    private static let paceLineHeight: CGFloat = 16
    private static let costSectionHeight: CGFloat = 70
    private static let actionRowHeight: CGFloat = 20
    private static let accountsSectionHeaderHeight: CGFloat = 28
    private static let errorLineHeight: CGFloat = 20
    private static let dividerHeight: CGFloat = 1

    // MARK: Quota risk summary

    private var quotaRisk: QuotaRiskItem? {
        var candidates: [QuotaRiskItem] = []
        let privacy = SettingsStore.shared.privacyMode
        for provider in appState.visibleProviders {
            for (index, account) in appState.accounts(for: provider).enumerated() {
                guard let snapshot = appState.quotaState(for: account).snapshot else { continue }
                let title = "\(provider.displayName) · \(account.shortTitle(index: index, privacy: privacy))"
                for window in [snapshot.primary, snapshot.secondary].compactMap({ $0 }) {
                    candidates.append(QuotaRiskItem(title: title, window: window, tint: provider.accent))
                }
            }
        }
        return candidates
            .filter { $0.remainingPercent <= 20 }
            .min { lhs, rhs in lhs.remainingPercent < rhs.remainingPercent }
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
                Text("\(risk.title) · \(risk.window.kind.shortLabel)")
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
        guard let latest = appState.latestVisibleSuccess else {
            return appState.hasVisibleError ? .offline : nil
        }
        let interval = SettingsStore.shared.quotaInterval.seconds ?? 300
        let age = Date().timeIntervalSince(latest)
        if age <= interval * 1.5 { return .live }
        if age <= interval * 3 { return .stale }
        return .offline
    }

    // MARK: Actions

    /// Accessory apps do not come to the front on their own; activate first so
    /// the window opens above everything else.
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

    /// Always spin the icon for feedback; `refreshNow` deduplicates the real work.
    private func refresh() {
        refreshRotation += 360
        Task { await appState.refreshNow() }
    }

    private func toggleMenuBarQuotaWindow() {
        SettingsStore.shared.menuBarWindow = SettingsStore.shared.menuBarWindow.toggledForMenuBar
        FloatingPanelController.shared.sync()
    }

    // MARK: Helpers

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
    let window: QuotaWindow
    let tint: Color

    var remainingPercent: Double {
        window.remainingPercent
    }
}

// MARK: - Week bounds shared by popover rows

enum UsageWeek {
    static func bounds(now: Date = Date()) -> (Date, Date) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        cal.firstWeekday = 2
        let startOfToday = cal.startOfDay(for: now)
        let startOfTomorrow = cal.date(byAdding: .day, value: 1, to: startOfToday) ?? startOfToday
        let comps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)
        let weekStart = cal.date(from: comps) ?? startOfToday
        return (weekStart, startOfTomorrow)
    }
}

// MARK: - ServiceBlockView
//
// One account card, modelled on CodexBar's menu card: header (tile, name,
// identity, refresh age, plan), one section per quota window (title, bar,
// percent left + reset countdown, pace line), then a local cost / token section.

struct ServiceBlockView: View {
    let account: MonitoredAccount
    let state: AccountQuotaState
    let subtitle: String
    let todayTotals: UsageTotals?
    let weekTotals: UsageTotals?
    let monthTotals: UsageTotals?
    let serviceStatus: ServiceStatus?
    /// Called after a ccpm action (set-default) so the caller can rediscover accounts.
    var onProfilesChanged: () -> Void = {}
    @State private var actionError: String?

    private var descriptor: ProviderDescriptor { account.descriptor }
    private var tint: Color { account.provider.accent }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            headerRow
            ForEach(Array(lanes.enumerated()), id: \.offset) { _, lane in
                laneSection(lane.window, kind: lane.kind)
            }
            if !account.usageRoots.isEmpty {
                usageSection
            }
            actionRow
            if let actionError {
                Text(actionError)
                    .font(.system(size: 10.5))
                    .foregroundStyle(quotaPaceAheadColor)
                    .lineLimit(2)
            }
            if let message = shortError(state.error) {
                Text(message)
                    .font(.system(size: 10.5))
                    .foregroundStyle(quotaPaceAheadColor)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Header

    private var headerRow: some View {
        HStack(alignment: .top, spacing: 9) {
            ServiceTile(logoName: descriptor.logoName, fallback: descriptor.fallbackGlyph, tint: tint)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(descriptor.displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .kerning(-0.1)
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary.opacity(0.75))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(refreshLine(now: context.date))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            if let plan = state.snapshot?.planType ?? account.identity.plan, !plan.isEmpty {
                Text(plan.replacingOccurrences(of: "_", with: " ").capitalized)
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
                    .padding(.top, 5)
                    .help(serviceStatusTooltip(status))
            }
        }
    }

    private func refreshLine(now: Date) -> String {
        var parts: [String] = []
        if state.refresh.inFlight {
            parts.append(tr("Refreshing…", "刷新中…"))
        } else if let last = state.refresh.lastSuccessAt {
            let age = PopoverRootView.relativeAge(from: last, now: now)
            parts.append(tr("Updated \(age) ago", "\(age) 前更新"))
        } else if state.error != nil {
            parts.append(tr("Refresh failed", "刷新失败"))
        } else {
            parts.append(tr("Waiting for first refresh", "等待首次刷新"))
        }
        if let source = state.source, source != .api {
            parts.append(source.displayName)
        }
        return parts.joined(separator: " · ")
    }

    private func serviceStatusTooltip(_ status: ServiceStatus) -> String {
        let trimmed = status.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let head = trimmed.isEmpty ? status.indicator.label : trimmed
        guard let updatedAt = status.updatedAt else { return head }
        let age = PopoverRootView.relativeAge(from: updatedAt)
        return tr("\(head) · updated \(age) ago", "\(head) · \(age) 前更新")
    }

    // MARK: Lanes

    private struct Lane {
        let kind: QuotaWindowKind
        let window: QuotaWindow?
    }

    /// Every window the snapshot carries, primary first; placeholders for the
    /// descriptor's lanes while nothing has been fetched yet.
    private var lanes: [Lane] {
        if let snapshot = state.snapshot {
            return snapshot.allWindows.map { Lane(kind: $0.kind, window: $0) }
        }
        var placeholders = [Lane(kind: descriptor.primaryKind, window: nil)]
        if let secondary = descriptor.secondaryKind {
            placeholders.append(Lane(kind: secondary, window: nil))
        }
        return placeholders
    }

    private func laneSection(_ window: QuotaWindow?, kind: QuotaWindowKind) -> some View {
        let color = laneColor(window)
        let pace = window.flatMap { QuotaPace.compute(window: $0) }
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(kind.laneTitle)
                    .font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 8)
                if let detail = window?.detail {
                    Text(detail)
                        .font(.system(size: 10.5))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            ProgressBar(value: (window?.remainingPercent ?? 0) / 100, tint: color, height: 6)

            HStack(alignment: .firstTextBaseline) {
                Text(window.map { tr("\(Int($0.remainingPercent.rounded()))% left", "剩余 \(Int($0.remainingPercent.rounded()))%") } ?? "--%")
                    .font(.system(size: 11.5, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(color)
                Spacer(minLength: 8)
                ResetTimeHint(resetsAt: window?.resetsAt)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            if let pace {
                Text(paceText(pace, window: window))
                    .font(.system(size: 10.5))
                    .monospacedDigit()
                    .foregroundStyle(pace.deltaPercent > 0 ? quotaPaceAheadColor : .secondary)
                    .lineLimit(1)
            }
        }
    }

    private func paceText(_ pace: QuotaPace, window: QuotaWindow?) -> String {
        let head: String
        if pace.deltaPercent > 0 {
            head = tr("Pace: ahead +\(pace.deltaPercent)%", "节奏：超前 +\(pace.deltaPercent)%")
        } else if pace.deltaPercent < 0 {
            head = tr("Pace: behind \(pace.deltaPercent)%", "节奏：落后 \(pace.deltaPercent)%")
        } else {
            head = tr("Pace: on track", "节奏：正常")
        }
        if let runsOutAt = pace.runsOutAt {
            return "\(head) · " + tr("runs out in \(formatResetCompact(runsOutAt))", "预计 \(formatResetCompact(runsOutAt)) 后耗尽")
        }
        return "\(head) · " + tr("lasts to reset", "可撑到重置")
    }

    private func laneColor(_ window: QuotaWindow?) -> Color {
        guard let window else { return .secondary }
        return statusColor(remainingPercent: window.remainingPercent, tint: tint)
    }

    // MARK: Local usage

    private var usageSection: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(descriptor.supportsCost ? tr("Cost", "花费") : tr("Tokens", "令牌"))
                .font(.system(size: 12, weight: .semibold))
            usageLine(tr("Today", "今日"), todayTotals)
            usageLine(tr("This week", "本周"), weekTotals)
            usageLine(tr("Last 30 days", "最近 30 天"), monthTotals)
        }
    }

    private func usageLine(_ label: String, _ totals: UsageTotals?) -> some View {
        HStack(spacing: 0) {
            Text("\(label): ")
                .foregroundStyle(.secondary)
            Text(usageValue(totals))
                .foregroundStyle(.primary)
                .monospacedDigit()
        }
        .font(.system(size: 11))
        .lineLimit(1)
    }

    private func usageValue(_ totals: UsageTotals?) -> String {
        guard let totals else { return "—" }
        let tokens = StatsFormatter.compactToken(totals.totalTokens) + " tokens"
        if descriptor.supportsCost {
            return "\(StatsFormatter.cost(totals.costUSD)) · \(tokens)"
        }
        return tokens
    }

    // MARK: Actions

    private var ccpmProfile: String? {
        if case .ccpm(let profile) = account.source { return profile }
        return nil
    }

    private var actionRow: some View {
        HStack(spacing: 0) {
            if let url = account.dashboardURL {
                actionButton(tr("Dashboard", "用量面板")) { NSWorkspace.shared.open(url) }
            }
            if let url = descriptor.statusPageWebURL {
                actionSeparator(after: account.dashboardURL != nil)
                actionButton(tr("Status", "状态页")) { NSWorkspace.shared.open(url) }
            }
            if let profile = ccpmProfile, account.provider != .codex {
                actionSeparator(after: account.dashboardURL != nil || descriptor.statusPageWebURL != nil)
                actionButton(tr("Terminal", "终端")) {
                    do {
                        actionError = nil
                        try CCPMCommand.openInTerminal(profile: profile)
                    } catch {
                        actionError = "\(error)"
                    }
                }
                if !account.identity.isDefaultProfile {
                    actionSeparator(after: true)
                    actionButton(tr("Set default", "设为默认")) {
                        actionError = nil
                        Task {
                            do {
                                try await CCPMCommand.setDefault(profile: profile)
                                onProfilesChanged()
                            } catch {
                                actionError = "\(error)"
                            }
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func actionButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
    }

    @ViewBuilder
    private func actionSeparator(after hasPrevious: Bool) -> some View {
        if hasPrevious {
            Text(" · ")
                .font(.system(size: 10.5))
                .foregroundStyle(.quaternary)
        }
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
private struct ResetTimeHint: View {
    let resetsAt: Date?
    @State private var hovering = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            Text(hovering ? formatResetAltCompact(resetsAt, now: context.date) : formatResetHint(resetsAt, now: context.date))
                .monospacedDigit()
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }
    }
}

extension QuotaWindowKind {
    @MainActor
    var laneTitle: String {
        switch self {
        case .fiveHour: return tr("Session · 5h", "5 小时")
        case .weekly: return tr("Weekly", "周额度")
        case .monthly: return tr("Monthly", "月额度")
        case .weeklyOpus: return tr("Opus · weekly", "Opus · 周")
        case .weeklySonnet: return tr("Sonnet · weekly", "Sonnet · 周")
        case .mcp: return tr("MCP · monthly", "MCP · 月")
        case .extraUsage: return tr("Extra usage · monthly", "超额用量 · 月")
        }
    }
}

// MARK: - Account subtitle

extension MonitoredAccount {
    /// "Default · me@x.com · Pro" / "imported · alias · me@x.com" / "ccpm · work · api.kimi.com".
    @MainActor
    func popoverSubtitle(index: Int) -> String {
        let privacy = SettingsStore.shared.privacyMode
        var parts: [String] = []
        switch source {
        case .defaultLogin:
            parts.append(tr("Default", "默认"))
            if !privacy, let email = identity.email, !email.isEmpty { parts.append(email) }
        case .importedCodex:
            parts.append("imported")
            if privacy {
                parts.append(tr("Account \(index + 1)", "账号 \(index + 1)"))
            } else {
                parts.append(shortTitle(index: index, privacy: false))
                if let email = identity.email, !email.isEmpty, email != parts.last { parts.append(email) }
            }
        case .ccpm(let profile):
            parts.append("ccpm")
            if privacy {
                parts.append(tr("Profile \(index + 1)", "账号 \(index + 1)"))
            } else {
                parts.append(profile)
                if let email = identity.email, !email.isEmpty { parts.append(email) }
                if case .apiKey(_, let baseURL) = credential, let host = baseURL.host { parts.append(host) }
            }
            if identity.isDefaultProfile { parts.append("Default") }
        }
        if let plan = identity.plan, !plan.isEmpty {
            parts.append(plan.replacingOccurrences(of: "_", with: " ").capitalized)
        }
        if parts.count == 1, source == .defaultLogin {
            parts.append(descriptor.vendor)
        }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}
