import SwiftUI

// MARK: - SettingsRootView
//
// PrefsGroup + PrefsRow cards (system `Form .grouped` is too weak for this look).
// Every provider-specific list is generated from `Provider.allCases`.

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
            PrefsGroup(
                title: "Accounts",
                chinese: "账号",
                desc: "Auto-detected on your Mac and from ccpm. Toggle which services to display.",
                chineseDesc: "从本机登录与 ccpm 自动检测,可勾选要显示的服务"
            ) {
                ForEach(Provider.allCases, id: \.self) { provider in
                    let accounts = appState.accounts(for: provider)
                    AccountRow(
                        provider: provider,
                        email: accounts.first(where: { $0.identity.email != nil })?.identity.email,
                        plan: accounts.first(where: { $0.identity.plan != nil })?.identity.plan,
                        accountCount: accounts.count,
                        isAvailable: accounts.contains { $0.credential.canFetchQuota || appState.quotaState(for: $0).snapshot != nil },
                        isOn: Binding(
                            get: { settings.isEnabled(provider) },
                            set: { setServiceEnabled(provider, enabled: $0) }
                        )
                    )
                }
            }

            PrefsGroup(
                title: "ccpm Profiles",
                chinese: "ccpm 账号",
                desc: "Auto-discovered from ~/.ccpm/config.json. OAuth profiles use their own credentials; Kimi / GLM read the key from the ccpm keystore; Ollama Cloud needs a pasted cookie.",
                chineseDesc: "自动读取 ~/.ccpm/config.json;OAuth profile 用各自凭据,Kimi / GLM 从 ccpm keystore 取 key,Ollama Cloud 需要粘贴 Cookie"
            ) {
                CCPMProfilesView()
            }

            PrefsGroup(
                title: "Other Codex Accounts",
                chinese: "其他 Codex 账号",
                desc: "Paste auth.json to monitor additional Codex accounts (view only).",
                chineseDesc: "粘贴 auth.json 添加更多 Codex 账号额度，仅查看，不会切换 CLI 登录状态"
            ) {
                ImportedCodexAccountsView()
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
            ForEach(Provider.allCases, id: \.self) { provider in
                PrefsRow(label: "Show \(provider.displayName)", chinese: "显示 \(provider.displayName)") {
                    Toggle("", isOn: Binding(
                        get: { settings.menuBarProviders.contains(provider) },
                        set: { settings.setMenuBar(provider, $0) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(.green)
                    .disabled(!settings.isEnabled(provider) || !appState.presentProviders.contains(provider))
                }
            }
            PrefsRow(
                label: "Display mode",
                chinese: "显示模式",
                desc: "All enabled providers, or only the one closest to its limit.",
                chineseDesc: "显示所有已启用服务,或只显示剩余最低的那个"
            ) {
                Picker("", selection: Binding(
                    get: { settings.menuBarMode },
                    set: { settings.menuBarMode = $0 }
                )) {
                    Text(tr("All", "全部")).tag(MenuBarMode.all)
                    Text(tr("Lowest only", "仅最低")).tag(MenuBarMode.lowestOnly)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }
            PrefsRow(
                label: "Icon style",
                chinese: "图标样式",
                desc: "Percent text or a small vertical meter next to each logo.",
                chineseDesc: "logo 旁显示百分比文字或竖向量表"
            ) {
                Picker("", selection: Binding(
                    get: { settings.menuBarStyle },
                    set: { settings.menuBarStyle = $0 }
                )) {
                    Text(tr("Percent", "百分比")).tag(MenuBarStyle.percent)
                    Text(tr("Meter", "量表")).tag(MenuBarStyle.meter)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }
            PrefsRow(
                label: "Quota period",
                chinese: "额度周期",
                desc: "Which window to display: primary (5H, monthly for Ollama) or secondary (WK).",
                chineseDesc: "显示主窗口(5H,Ollama 为月)还是副窗口(WK)"
            ) {
                Picker("", selection: Binding(
                    get: { settings.menuBarWindow },
                    set: { newValue in
                        settings.menuBarWindow = newValue
                        FloatingPanelController.shared.sync()
                    }
                )) {
                    Text(tr("Primary · 5H", "主窗口 · 5H")).tag(MenuBarWindowChoice.primary)
                    Text(tr("Secondary · WK", "副窗口 · WK")).tag(MenuBarWindowChoice.secondary)
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
            ForEach(Provider.allCases, id: \.self) { provider in
                PrefsRow(label: "Show \(provider.displayName) row", chinese: "显示 \(provider.displayName) 行") {
                    Toggle("", isOn: Binding(
                        get: { settings.floatingProviders.contains(provider) },
                        set: { newValue in
                            settings.setFloating(provider, newValue)
                            FloatingPanelController.shared.sync()
                        }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(.green)
                    .disabled(!settings.floatingEnabled || !settings.isEnabled(provider) || !appState.presentProviders.contains(provider))
                }
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
                label: "Quota notifications",
                chinese: "额度通知",
                desc: "Notify at 20% left, when a window is exhausted, and when a weekly window resets.",
                chineseDesc: "剩余 20%、用尽以及周额度重置时通知"
            ) {
                Toggle("", isOn: Binding(get: { settings.quotaNotifications }, set: { settings.quotaNotifications = $0 }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(.green)
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
                desc: "Hide emails and account names in the popover.",
                chineseDesc: "弹出窗口中隐藏邮箱与账号名称"
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
            Text(tr("cc-bar \(appVersion) · quotas for every coding provider you use",
                    "CCBar \(appVersion) · 多 Provider 额度与本地用量统计"))
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.top, 8)
    }

    // MARK: Helpers

    private func setServiceEnabled(_ provider: Provider, enabled: Bool) {
        SettingsStore.shared.setEnabled(provider, enabled)
        FloatingPanelController.shared.sync()

        guard enabled else { return }
        Task {
            await appState.refreshQuotas(reason: .userInitiated)
            await appState.refreshServiceStatus()
        }
    }

    private var lastRefreshText: String {
        let latest = appState.accounts.compactMap { appState.quotaState(for: $0).refresh.lastSuccessAt }.max()
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
}

// MARK: - PrefsGroup

struct PrefsGroup<Content: View>: View {
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

struct PrefsRow<Trailing: View>: View {
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
    let provider: Provider
    let email: String?
    let plan: String?
    let accountCount: Int
    let isAvailable: Bool
    @Binding var isOn: Bool

    private var descriptor: ProviderDescriptor { provider.descriptor }

    var body: some View {
        HStack(spacing: 11) {
            ServiceTile(
                logoName: descriptor.logoName,
                fallback: descriptor.fallbackGlyph,
                tint: provider.accent,
                size: 28,
                logoSize: 16,
                cornerRadius: 7
            )

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(descriptor.displayName)
                        .font(.system(size: 12.5, weight: .semibold))
                    Text("· \(descriptor.vendor)")
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
        var parts: [String] = []
        if let email, !SettingsStore.shared.privacyMode { parts.append(email) }
        if let plan, !plan.isEmpty { parts.append(plan) }
        if accountCount > 1 {
            parts.append(tr("\(accountCount) accounts", "\(accountCount) 个账号"))
        }
        if parts.isEmpty {
            return isAvailable ? tr("Detected", "已识别") : tr("Not detected", "未识别")
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var statusBadge: some View {
        if isAvailable {
            HStack(spacing: 4) {
                Circle().fill(Color.green).frame(width: 6, height: 6)
                Text(email != nil ? tr("Connected", "已连接") : tr("Available", "可用"))
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

// MARK: - Bilingual display names for interval enums

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
