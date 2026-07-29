import SwiftUI

// MARK: - SettingsRootView
//
// 见 docs/04-界面布局.md §4。
// 使用 prototype 的 PrefsGroup + PrefsRow 卡片结构,放弃 Form .grouped。

struct SettingsRootView: View {
    @Environment(AppState.self) private var appState
    @State private var launchAtLoginError: String?

    var body: some View {
        @Bindable var settings = SettingsStore.shared

        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                accountsGroup(settings: settings)
                menuBarGroup(settings: settings)
                floatingGroup(settings: settings)
                refreshGroup(settings: settings)
                generalGroup(settings: settings)
                footer
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    // MARK: Accounts

    private func accountsGroup(settings: SettingsStore) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            // 主账号（自动检测）
            PrefsGroup(
                title: "Accounts",
                chinese: "账号",
                desc: "Auto-detected on your Mac. Toggle which services to display.",
                chineseDesc: "自动检测,可勾选要显示的服务"
            ) {
                AccountRow(
                    title: "Codex",
                    subtitle: "OpenAI",
                    tint: .codexAccent,
                    logoName: "codex",
                    fallback: "C",
                    email: appState.codexAccount?.email,
                    plan: appState.codexAccount?.planType,
                    fallbackDetail: appState.importedCodexAccounts.isEmpty && !appState.hasCCPMCodexProfiles
                        ? nil
                        : tr("Additional accounts configured", "已配置其他账号"),
                    isAvailable: appState.codexAccount != nil
                        || !appState.importedCodexAccounts.isEmpty
                        || appState.hasCCPMCodexProfiles,
                    isOn: Binding(
                        get: { settings.showCodex },
                        set: { setServiceEnabled(.codex, enabled: $0) }
                    )
                )
                AccountRow(
                    title: "Claude Code",
                    subtitle: "Anthropic",
                    tint: .claudeAccent,
                    logoName: "claude",
                    fallback: "K",
                    email: appState.claudeAccount?.email,
                    plan: appState.claudeAccount?.subscriptionType,
                    fallbackDetail: appState.ccpmClaudeProfiles.isEmpty
                        ? nil
                        : tr("ccpm profiles configured", "已配置 ccpm profile"),
                    isAvailable: appState.claudeAccount != nil || !appState.ccpmClaudeProfiles.isEmpty,
                    isOn: Binding(
                        get: { settings.showClaude },
                        set: { setServiceEnabled(.claude, enabled: $0) }
                    )
                )
            }

            PrefsGroup(
                title: "Codex Profiles",
                chinese: "Codex 账号",
                desc: "Auto-discovered from ccpm. OAuth profiles are monitored from their native auth.json.",
                chineseDesc: "自动读取 ccpm 配置;OAuth profile 直接使用各自的 auth.json 独立监控"
            ) {
                CCPMCodexProfilesView()
            }

            // 其他 Codex 账号（手动导入）
            PrefsGroup(
                title: "Other Codex Accounts",
                chinese: "其他 Codex 账号",
                desc: "Paste auth.json to monitor additional Codex accounts (view only).",
                chineseDesc: "粘贴 auth.json 添加更多 Codex 账号额度，仅查看，不会切换 CLI 登录状态"
            ) {
                ImportedCodexAccountsView()
            }

            PrefsGroup(
                title: "Claude Code Profiles",
                chinese: "Claude Code 账号",
                desc: "Auto-discovered from ccpm. OAuth profiles are monitored independently.",
                chineseDesc: "自动读取 ccpm 配置;OAuth profile 会独立监控额度"
            ) {
                CCPMClaudeProfilesView()
            }
        }
    }

    // MARK: Menu Bar

    private func menuBarGroup(settings: SettingsStore) -> some View {
        PrefsGroup(
            title: "Menu Bar",
            chinese: "菜单栏",
            desc: "What appears next to the icon.",
            chineseDesc: "图标旁显示什么"
        ) {
            PrefsRow(label: "Show Codex", chinese: "显示 Codex") {
                Toggle("", isOn: Binding(get: { settings.menuBarShowCodex }, set: { settings.menuBarShowCodex = $0 }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(.green)
            }
            PrefsRow(label: "Show Claude", chinese: "显示 Claude") {
                Toggle("", isOn: Binding(get: { settings.menuBarShowClaude }, set: { settings.menuBarShowClaude = $0 }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(.green)
            }
            PrefsRow(
                label: "Quota period",
                chinese: "额度周期",
                desc: "Which window to display in the menu bar.",
                chineseDesc: "菜单栏显示哪个窗口"
            ) {
                Picker("", selection: Binding(
                    get: { settings.menuBarWindow },
                    set: { newValue in
                        settings.menuBarWindow = newValue
                        FloatingPanelController.shared.sync()
                    }
                )) {
                    Text("5H").tag(MenuBarWindowChoice.fiveHour)
                    Text("WK").tag(MenuBarWindowChoice.weekly)
                    Text(tr("Both", "都显示")).tag(MenuBarWindowChoice.both)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }
        }
    }

    // MARK: Floating HUD

    private func floatingGroup(settings: SettingsStore) -> some View {
        PrefsGroup(
            title: "Floating HUD",
            chinese: "桌面悬浮窗",
            desc: "A small always-on-top window pinned to your desktop.",
            chineseDesc: "桌面常驻的小悬浮窗"
        ) {
            PrefsRow(label: "Show floating window", chinese: "显示悬浮窗") {
                Toggle("", isOn: Binding(
                    get: { settings.floatingEnabled },
                    set: { newValue in
                        settings.floatingEnabled = newValue
                        FloatingPanelController.shared.sync()
                    }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(.green)
            }
            PrefsRow(label: "Show Codex row", chinese: "显示 Codex 行") {
                Toggle("", isOn: Binding(
                    get: { settings.floatingShowCodex },
                    set: { newValue in
                        settings.floatingShowCodex = newValue
                        FloatingPanelController.shared.sync()
                    }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(.green)
                .disabled(!settings.floatingEnabled)
            }
            PrefsRow(label: "Show Claude row", chinese: "显示 Claude 行") {
                Toggle("", isOn: Binding(
                    get: { settings.floatingShowClaude },
                    set: { newValue in
                        settings.floatingShowClaude = newValue
                        FloatingPanelController.shared.sync()
                    }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(.green)
                .disabled(!settings.floatingEnabled)
            }
        }
    }

    // MARK: Refresh

    private func refreshGroup(settings: SettingsStore) -> some View {
        PrefsGroup(
            title: "Refresh",
            chinese: "刷新",
            desc: "How often the app polls usage in the background.",
            chineseDesc: "后台轮询用量的频率"
        ) {
            PrefsRow(label: "Quota refresh", chinese: "额度刷新") {
                Picker("", selection: Binding(
                    get: { settings.quotaInterval },
                    set: { newValue in
                        settings.quotaInterval = newValue
                        appState.applySettingsChange()
                    }
                )) {
                    ForEach(QuotaIntervalChoice.allCases) { choice in
                        Text(choice.bilingualDisplayName).tag(choice)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }
            PrefsRow(label: "Log scan", chinese: "日志扫描") {
                Picker("", selection: Binding(
                    get: { settings.usageInterval },
                    set: { newValue in
                        settings.usageInterval = newValue
                        appState.applySettingsChange()
                    }
                )) {
                    ForEach(UsageIntervalChoice.allCases) { choice in
                        Text(choice.bilingualDisplayName).tag(choice)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }
            PrefsRow(
                label: "Reset time",
                chinese: "重置时间",
                desc: "How quota reset time is shown.",
                chineseDesc: "额度重置时间的显示方式"
            ) {
                Picker("", selection: Binding(
                    get: { settings.resetTimeDisplay },
                    set: { settings.resetTimeDisplay = $0 }
                )) {
                    Text(tr("Remaining", "剩余时长")).tag(ResetTimeDisplay.relative)
                    Text(tr("Exact time", "具体时间")).tag(ResetTimeDisplay.absolute)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }
            PrefsRow(label: "Last refresh", chinese: "上次刷新") {
                Text(lastRefreshText)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            PrefsRow(
                label: "Service status dot",
                chinese: "服务状态圆点",
                desc: "Show OpenAI / Anthropic status next to each service in the popover.",
                chineseDesc: "在弹出窗口为每个服务显示官方状态页圆点"
            ) {
                Toggle("", isOn: Binding(get: { settings.showServiceStatus }, set: { settings.showServiceStatus = $0 }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(.green)
            }
        }
    }

    // MARK: General

    private func generalGroup(settings: SettingsStore) -> some View {
        PrefsGroup(title: "General", chinese: "通用") {
            PrefsRow(label: "Language", chinese: "语言") {
                Picker("", selection: Binding(
                    get: { settings.appLanguage },
                    set: { settings.appLanguage = $0 }
                )) {
                    ForEach(AppLanguage.allCases) { lang in
                        Text(lang.displayName).tag(lang)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }
            PrefsRow(
                label: "Privacy mode",
                chinese: "隐私模式",
                desc: "Hide email in the popover and account names for other Codex accounts.",
                chineseDesc: "弹出窗口中隐藏主账号邮箱,并隐藏 Codex 副账号名称"
            ) {
                Toggle("", isOn: Binding(get: { settings.privacyMode }, set: { settings.privacyMode = $0 }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(.green)
            }
            PrefsRow(label: "Launch at login", chinese: "开机自动启动") {
                Toggle("", isOn: Binding(
                    get: { settings.launchAtLogin },
                    set: { newValue in
                        do {
                            try settings.setLaunchAtLogin(newValue)
                            launchAtLoginError = nil
                        } catch {
                            launchAtLoginError = error.localizedDescription
                        }
                    }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(.green)
            }
            if let launchAtLoginError {
                PrefsRow(label: "Error", chinese: "错误") {
                    Text(launchAtLoginError)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                        .lineLimit(2)
                        .frame(maxWidth: 200, alignment: .trailing)
                }
            }
            PrefsRow(label: "Version", chinese: "版本") {
                Text(appVersion)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text(tr("cc-bar \(shortVersion) · made with Liquid Glass",
                    "CCBar \(shortVersion) · 双应用额度与本地用量统计"))
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.top, 8)
    }

    // MARK: Helpers

    private func setServiceEnabled(_ service: UsageApp, enabled: Bool) {
        let settings = SettingsStore.shared
        switch service {
        case .codex:
            settings.showCodex = enabled
        case .claude:
            settings.showClaude = enabled
        }
        FloatingPanelController.shared.sync()

        guard enabled else { return }
        Task {
            await appState.refreshQuotas(reason: .userInitiated)
            await appState.refreshServiceStatus()
        }
    }

    private var lastRefreshText: String {
        let latest = [
            appState.codexRefreshState.lastSuccessAt,
            appState.claudeRefreshState.lastSuccessAt,
            appState.importedCodexRefreshStates.values.compactMap(\.lastSuccessAt).max(),
            appState.ccpmCodexRefreshStates.values.compactMap(\.lastSuccessAt).max(),
            appState.ccpmClaudeRefreshStates.values.compactMap(\.lastSuccessAt).max()
        ].compactMap { $0 }.max()
        guard let latest else { return "—" }
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH:mm:ss"
        timeFormatter.locale = Locale(identifier: "en_US_POSIX")
        return "\(timeFormatter.string(from: latest)) · \(PopoverRootView.relativeAge(from: latest)) \(tr("ago", "前"))"
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        return info?["CFBundleShortVersionString"] as? String ?? "0.0"
    }

    private var shortVersion: String {
        let info = Bundle.main.infoDictionary
        return info?["CFBundleShortVersionString"] as? String ?? "1.0"
    }
}

// MARK: - PrefsGroup

private struct PrefsGroup<Content: View>: View {
    let title: String
    let chinese: String
    var desc: String? = nil
    var chineseDesc: String? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(tr(title, chinese))
                    .font(.system(size: 12, weight: .semibold))
                    .kerning(-0.05)
                if let desc, let chineseDesc {
                    Text(tr(desc, chineseDesc))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 8)

            VStack(spacing: 0) {
                content()
            }
            .ccPanel(cornerRadius: 10)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }
}

// MARK: - PrefsRow

private struct PrefsRow<Trailing: View>: View {
    let label: String
    let chinese: String
    var desc: String? = nil
    var chineseDesc: String? = nil
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(tr(label, chinese))
                    .font(.system(size: 12.5))
                if let desc, let chineseDesc {
                    Text(tr(desc, chineseDesc))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            trailing()
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
    }
}

// MARK: - AccountRow

private struct AccountRow: View {
    let title: String
    let subtitle: String
    let tint: Color
    let logoName: String
    let fallback: String
    let email: String?
    let plan: String?
    let fallbackDetail: String?
    let isAvailable: Bool
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 11) {
            ServiceTile(logoName: logoName, fallback: fallback, tint: tint, size: 28, logoSize: 16, cornerRadius: 7)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(title)
                        .font(.system(size: 12.5, weight: .semibold))
                    Text("· \(subtitle)")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                Text(detailText)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 8) {
                statusBadge

                Toggle("", isOn: $isOn)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(.green)
                    .disabled(!isAvailable)
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
    }

    private var detailText: String {
        if let email {
            if let plan, !plan.isEmpty {
                return "\(email) · \(plan)"
            }
            return email
        }
        if let fallbackDetail {
            return fallbackDetail
        }
        return tr("Not detected", "未识别")
    }

    @ViewBuilder
    private var statusBadge: some View {
        if email != nil {
            HStack(spacing: 4) {
                Circle().fill(Color.green).frame(width: 6, height: 6)
                Text(tr("Connected", "已连接"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.green)
            }
        } else if isAvailable {
            HStack(spacing: 4) {
                Circle().fill(Color.green).frame(width: 6, height: 6)
                Text(tr("Available", "可用"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.green)
            }
        } else {
            HStack(spacing: 4) {
                Circle().fill(Color.orange).frame(width: 6, height: 6)
                Text(tr("Not detected", "未识别"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.orange)
            }
        }
    }
}

// MARK: - Bilingual display names for existing enums

extension QuotaIntervalChoice {
    @MainActor
    var bilingualDisplayName: String {
        switch self {
        case .m1: return tr("1 minute", "1 分钟")
        case .m2: return tr("2 minutes", "2 分钟")
        case .m3: return tr("3 minutes", "3 分钟")
        case .m5: return tr("5 minutes", "5 分钟")
        case .m10: return tr("10 minutes", "10 分钟")
        }
    }
}

extension UsageIntervalChoice {
    @MainActor
    var bilingualDisplayName: String {
        switch self {
        case .m1: return tr("1 minute", "1 分钟")
        case .m2: return tr("2 minutes", "2 分钟")
        case .m3: return tr("3 minutes", "3 分钟")
        case .m5: return tr("5 minutes", "5 分钟")
        case .m10: return tr("10 minutes", "10 分钟")
        }
    }
}
