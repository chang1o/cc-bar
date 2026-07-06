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

            Divider()

            content
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

            Button { activateAndOpenMain() } label: {
                Image(systemName: "chart.bar.xaxis")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(PopoverIconButtonStyle())
            .help(tr("Open Statistics", "查看统计"))

            Button { activateAndOpenMain() } label: {
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
        let apps = enabledPrimaryApps
        let latest = apps.compactMap {
            appState.refreshState(for: $0).lastSuccessAt
        }.max()

        if let latest {
            let age = Self.relativeAge(from: latest, now: now)
            return tr("refreshed \(age) ago", "\(age) 前已刷新")
        }
        if apps.contains(where: { appState.quotaError(for: $0) != nil }) {
            return tr("refresh failed", "刷新失败")
        }
        return tr("waiting…", "等待数据")
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        let providers = QuotaProviderDescriptor.primaryProviders.filter {
            SettingsStore.shared.isProviderEnabled($0.app)
        }
        let hasImported = appState.importedCodexAccounts.contains(where: \.visibleInPopover)
        let includesCodex = providers.contains(where: { $0.app == .codex })

        if providers.isEmpty && !hasImported {
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
                if hasImported && !includesCodex {
                    OtherCodexAccountsSection()
                    if !providers.isEmpty {
                        Divider().padding(.horizontal, 16)
                    }
                }

                ForEach(Array(providers.enumerated()), id: \.element.app) { index, provider in
                    if index > 0 {
                        Divider().padding(.horizontal, 16)
                    }
                    primaryServiceBlock(provider)

                    if provider.app == .codex && hasImported {
                        Divider().padding(.horizontal, 16)
                        OtherCodexAccountsSection()
                    }
                }
            }
        }
    }

    private func providerSubtitle(for app: QuotaApp) -> String {
        let privacy = SettingsStore.shared.privacyMode
        var parts: [String] = []
        let email: String?
        let plan: String?
        let fallback: String
        switch app {
        case .codex:
            email = appState.codexAccount?.email
            plan = appState.codexAccount?.planType?.capitalized
            fallback = "OpenAI"
        case .claude:
            email = appState.claudeAccount?.email
            plan = appState.claudeAccount?.subscriptionType?.capitalized
            fallback = "Anthropic"
        case .antigravity:
            email = appState.antigravityAccount?.email
            plan = appState.antigravityAccount?.planType
            fallback = "Google"
        }
        if !privacy, let email, !email.isEmpty { parts.append(email) }
        if let plan, !plan.isEmpty { parts.append(plan) }
        if parts.isEmpty { parts.append(fallback) }
        return parts.joined(separator: " · ")
    }

    private func primaryServiceBlock(
        _ provider: QuotaProviderDescriptor
    ) -> some View {
        let snap = appState.quotaSnapshot(for: provider.app)
        return ServiceBlockView(
            title: provider.title,
            subtitle: providerSubtitle(for: provider.app),
            tint: provider.app.tintColor,
            logoName: provider.logoName,
            fallback: provider.fallback,
            snapshot: snap,
            error: appState.quotaError(for: provider.app),
            weekSpend: weekSpend(for: provider.app),
            todayCost: todayCost(for: provider.app),
            serviceStatus: serviceStatus(for: provider.app),
            geminiWindow: snap?.geminiWindow,
            geminiWeekly: snap?.geminiWeekly
        )
    }

    private func weekSpend(for app: QuotaApp) -> Decimal? {
        let usageApp: UsageApp
        switch app {
        case .codex: usageApp = .codex
        case .claude: usageApp = .claude
        case .antigravity: return nil
        }
        let (from, to) = Self.weekBounds()
        let totals = appState.usageService.aggregator.totals(app: usageApp, from: from, to: to)
        return totals.costUSD
    }

    private func todayCost(for app: QuotaApp) -> Decimal? {
        switch app {
        case .codex: appState.codexTodayCost
        case .claude: appState.claudeTodayCost
        case .antigravity: nil
        }
    }

    private func serviceStatus(for app: QuotaApp) -> ServiceStatus? {
        guard SettingsStore.shared.showServiceStatus else { return nil }
        return switch app {
        case .codex: appState.codexServiceStatus
        case .claude: appState.claudeServiceStatus
        case .antigravity: nil as ServiceStatus?
        }
    }

    // MARK: Header state (live / stale / offline)

    private var headerState: CCRefreshState? {
        let settings = SettingsStore.shared
        let states = enabledPrimaryApps.map { appState.refreshState(for: $0) }
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

    private var enabledPrimaryApps: [QuotaApp] {
        QuotaProviderDescriptor.primaryProviders.compactMap {
            SettingsStore.shared.isProviderEnabled($0.app) ? $0.app : nil
        }
    }

    // MARK: Open main window

    /// 菜单栏 App (`.accessory`) 默认不抢焦点,打开窗口后会被压在其他 App 后面;
    /// 先 `activate(ignoringOtherApps:)` 把进程置前,再 `openWindow` 才会出现在最前。
    private func activateAndOpenMain() {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "main")
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

// MARK: - ServiceBlockView

private struct ServiceBlockView: View {
    let title: String
    let subtitle: String
    let tint: Color
    let logoName: String
    let fallback: String
    let snapshot: QuotaSnapshot?
    let error: String?
    let weekSpend: Decimal?
    let todayCost: Decimal?
    let serviceStatus: ServiceStatus?
    var geminiWindow: QuotaWindow? = nil
    var geminiWeekly: QuotaWindow? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerRow
            bodyRow
            weeklyRow
            if let gemini = geminiWindow {
                geminiRow(gemini)
            }
            if let geminiWk = geminiWeekly {
                geminiWeeklyRow(geminiWk)
            }
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
            // 左:5h 大百分比 + 小标签
            VStack(alignment: .center, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text(fiveHourValueText)
                        .font(.system(size: 32, weight: .semibold))
                        .monospacedDigit()
                        .kerning(-0.8)
                        .foregroundStyle(fiveHourColor)
                        .lineLimit(1)
                    Text("%")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(fiveHourColor.opacity(0.75))
                }
                .fixedSize()

                Text("5-HOUR · 五小时")
                    .font(.system(size: 9, weight: .semibold))
                    .kerning(0.5)
                    .foregroundStyle(.quaternary)
            }

            // 右:5h 进度条 + 两行(数值 / label)
            VStack(alignment: .leading, spacing: 8) {
                ProgressBar(value: fiveHourRemaining / 100, tint: fiveHourColor, height: 7)

                VStack(spacing: 1) {
                    HStack(spacing: 0) {
                        ResetTimeText(resetsAt: snapshot?.fiveHour?.resetsAt)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        Spacer(minLength: 8)

                        if showsCost {
                            HStack(spacing: 10) {
                                statInline(value: formatCostInt(todayCost), english: "today", chinese: "今日")
                                statInline(value: formatCostInt(weekSpend), english: "this week", chinese: "本周")
                            }
                        }
                    }

                    HStack(spacing: 0) {
                        BilingualInline(english: "reset", chinese: "重置")
                            .font(.system(size: 9.5))
                            .foregroundStyle(.quaternary)

                        if showsCost {
                            Spacer(minLength: 0)

                            BilingualInline(english: "cost", chinese: "花费")
                                .font(.system(size: 9.5))
                                .foregroundStyle(.quaternary)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var weeklyRow: some View {
        HStack(spacing: 10) {
            Text("WK")
                .font(.system(size: 9, weight: .semibold))
                .kerning(0.6)
                .foregroundStyle(.quaternary)
                .frame(width: 36, alignment: .leading)

            ProgressBar(value: weeklyRemaining / 100, tint: weeklyColor, height: 2.5)

            Text(weeklyPercentText)
                .font(.system(size: 10.5, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(weeklyColor)

            ResetTimeText(resetsAt: snapshot?.weekly?.resetsAt)
                .font(.system(size: 10.5))
                .foregroundStyle(.quaternary)
        }
    }

    private func geminiRow(_ gemini: QuotaWindow) -> some View {
        let remaining = gemini.remainingPercent
        let color = statusColor(remainingPercent: remaining, tint: tint)
        return HStack(spacing: 10) {
            Text("GM")
                .font(.system(size: 9, weight: .semibold))
                .kerning(0.6)
                .foregroundStyle(.quaternary)
                .frame(width: 36, alignment: .leading)

            ProgressBar(value: remaining / 100, tint: color, height: 2.5)

            Text("\(Int(remaining.rounded()))%")
                .font(.system(size: 10.5, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(color)

            ResetTimeText(resetsAt: gemini.resetsAt)
                .font(.system(size: 10.5))
                .foregroundStyle(.quaternary)
        }
    }

    private func geminiWeeklyRow(_ geminiWk: QuotaWindow) -> some View {
        let remaining = geminiWk.remainingPercent
        let color = statusColor(remainingPercent: remaining, tint: tint)
        return HStack(spacing: 10) {
            Text("GW")
                .font(.system(size: 9, weight: .semibold))
                .kerning(0.6)
                .foregroundStyle(.quaternary)
                .frame(width: 36, alignment: .leading)

            ProgressBar(value: remaining / 100, tint: color, height: 2.5)

            Text("\(Int(remaining.rounded()))%")
                .font(.system(size: 10.5, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(color)

            ResetTimeText(resetsAt: geminiWk.resetsAt)
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

    private var fiveHourRemaining: Double {
        snapshot?.fiveHour?.remainingPercent ?? 0
    }

    private var weeklyRemaining: Double {
        snapshot?.weekly?.remainingPercent ?? 0
    }

    private var fiveHourColor: Color {
        guard snapshot?.fiveHour != nil else { return .secondary }
        return statusColor(remainingPercent: fiveHourRemaining, tint: tint)
    }

    private var weeklyColor: Color {
        guard snapshot?.weekly != nil else { return .secondary }
        return statusColor(remainingPercent: weeklyRemaining, tint: tint)
    }

    private var fiveHourValueText: String {
        guard let window = snapshot?.fiveHour else { return "--" }
        return "\(Int(window.remainingPercent.rounded()))"
    }

    private var weeklyPercentText: String {
        guard let window = snapshot?.weekly else { return "--%" }
        return "\(Int(window.remainingPercent.rounded()))%"
    }

    private var showsCost: Bool {
        weekSpend != nil
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
