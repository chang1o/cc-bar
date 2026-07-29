import SwiftUI

struct CodexAccountsSection: View {
    @Environment(AppState.self) private var appState
    let primaryWindow: MenuBarWindowChoice

    private var entries: [CodexMonitorEntry] {
        var result: [CodexMonitorEntry] = []
        if appState.codexAccount != nil
            || appState.codexQuota != nil
            || appState.codexQuotaError != nil
            || appState.codexRefreshState.inFlight {
            result.append(.primary)
        }
        result.append(
            contentsOf: appState.importedCodexAccounts
                .filter(\.visibleInPopover)
                .map { .imported($0) }
        )
        result.append(
            contentsOf: appState.ccpmCodexProfilesForMonitoring
                .map { .ccpmProfile($0) }
        )
        return result
    }

    var body: some View {
        let rows = entries
        if rows.isEmpty {
            EmptyView()
        } else {
            VStack(spacing: 0) {
                ServiceAccountsSectionHeader(
                    title: "CODEX ACCOUNTS",
                    chineseTitle: "Codex 账号",
                    count: rows.count
                )
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, entry in
                    if index > 0 {
                        Divider()
                            .padding(.horizontal, 16)
                    }
                    ServiceBlockView(
                        title: "Codex",
                        subtitle: subtitle(for: entry, index: index),
                        tint: .codexAccent,
                        logoName: "codex",
                        fallback: "C",
                        primaryWindow: primaryWindow,
                        snapshot: snapshot(for: entry),
                        error: error(for: entry),
                        weekSpend: weekSpend(for: entry),
                        todayCost: todayCost(for: entry),
                        serviceStatus: SettingsStore.shared.showServiceStatus
                            ? appState.codexServiceStatus
                            : nil
                    )
                }
            }
        }
    }

    private func subtitle(for entry: CodexMonitorEntry, index: Int) -> String {
        switch entry {
        case .primary:
            return primarySubtitle
        case .imported(let account):
            return importedSubtitle(account, index: index)
        case .ccpmProfile(let profile):
            return ccpmSubtitle(profile, index: index)
        }
    }

    private var primarySubtitle: String {
        var parts = [tr("Default", "默认")]
        if !SettingsStore.shared.privacyMode,
           let email = appState.codexAccount?.email,
           !email.isEmpty {
            parts.append(email)
        }
        if let plan = appState.codexAccount?.planType, !plan.isEmpty {
            parts.append(formattedPlan(plan))
        }
        return parts.joined(separator: " · ")
    }

    private func importedSubtitle(_ account: ImportedCodexAccount, index: Int) -> String {
        var parts = ["imported"]
        if SettingsStore.shared.privacyMode {
            parts.append(tr("Account \(index + 1)", "账号 \(index + 1)"))
        } else {
            if !account.alias.isEmpty {
                parts.append(account.alias)
            } else if let email = account.email, !email.isEmpty {
                parts.append(emailUsername(email))
            } else {
                parts.append(account.id)
            }
            if let email = account.email, !email.isEmpty {
                parts.append(email)
            }
        }
        if let plan = account.planType, !plan.isEmpty {
            parts.append(formattedPlan(plan))
        }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func ccpmSubtitle(_ profile: CCPMCodexProfile, index: Int) -> String {
        var parts = ["ccpm"]
        if SettingsStore.shared.privacyMode {
            parts.append(tr("Account \(index + 1)", "账号 \(index + 1)"))
        } else {
            parts.append(profile.name)
            if let email = profile.email, !email.isEmpty {
                parts.append(email)
            }
        }
        if profile.isDefault {
            parts.append("Default")
        }
        if let plan = profile.planType, !plan.isEmpty {
            parts.append(formattedPlan(plan))
        }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func snapshot(for entry: CodexMonitorEntry) -> QuotaSnapshot? {
        switch entry {
        case .primary:
            return appState.codexQuota
        case .imported(let account):
            return appState.importedCodexQuota(for: account)
        case .ccpmProfile(let profile):
            return appState.ccpmCodexQuota(for: profile)
        }
    }

    private func error(for entry: CodexMonitorEntry) -> String? {
        switch entry {
        case .primary:
            return appState.codexQuotaError
        case .imported(let account):
            return appState.importedCodexError(for: account)
        case .ccpmProfile(let profile):
            return appState.ccpmCodexError(for: profile)
        }
    }

    private func weekSpend(for entry: CodexMonitorEntry) -> Decimal? {
        switch entry {
        case .primary:
            let (from, to) = Self.weekBounds()
            return appState.usageService.aggregator.totals(app: .codex, from: from, to: to).costUSD
        case .imported, .ccpmProfile:
            return nil
        }
    }

    private func todayCost(for entry: CodexMonitorEntry) -> Decimal? {
        switch entry {
        case .primary:
            return appState.codexTodayCost
        case .imported, .ccpmProfile:
            return nil
        }
    }

    private func formattedPlan(_ plan: String) -> String {
        plan.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private func emailUsername(_ email: String) -> String {
        email.components(separatedBy: "@").first ?? email
    }

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
}

private enum CodexMonitorEntry: Identifiable {
    case primary
    case imported(ImportedCodexAccount)
    case ccpmProfile(CCPMCodexProfile)

    var id: String {
        switch self {
        case .primary:
            return "primary"
        case .imported(let account):
            return "imported:\(account.id)"
        case .ccpmProfile(let profile):
            return "ccpm:\(profile.id)"
        }
    }
}
