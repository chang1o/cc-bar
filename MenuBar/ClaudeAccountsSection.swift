import SwiftUI

struct ClaudeAccountsSection: View {
    @Environment(AppState.self) private var appState
    let primaryWindow: MenuBarWindowChoice

    private var entries: [ClaudeMonitorEntry] {
        var result: [ClaudeMonitorEntry] = []
        if appState.claudeAccount != nil
            || appState.claudeQuota != nil
            || appState.claudeQuotaError != nil
            || appState.claudeRefreshState.inFlight {
            result.append(.primary)
        }
        result.append(contentsOf: appState.ccpmClaudeProfilesForMonitoring.map { .ccpmProfile($0) })
        return result
    }

    var body: some View {
        let rows = entries
        if rows.isEmpty {
            EmptyView()
        } else {
            VStack(spacing: 0) {
                ServiceAccountsSectionHeader(
                    title: "CLAUDE CODE ACCOUNTS",
                    chineseTitle: "Claude Code 账号",
                    count: rows.count
                )
                ForEach(Array(rows.enumerated()), id: \.element.id) { idx, entry in
                    if idx > 0 {
                        Divider().padding(.horizontal, 16)
                    }
                    ServiceBlockView(
                        title: "Claude Code",
                        subtitle: subtitle(for: entry, index: idx),
                        tint: .claudeAccent,
                        logoName: "claude",
                        fallback: "K",
                        primaryWindow: primaryWindow,
                        snapshot: snapshot(for: entry),
                        error: error(for: entry),
                        weekSpend: weekSpend(for: entry),
                        todayCost: todayCost(for: entry),
                        serviceStatus: SettingsStore.shared.showServiceStatus ? appState.claudeServiceStatus : nil
                    )
                }
            }
        }
    }

    private func subtitle(for entry: ClaudeMonitorEntry, index: Int) -> String {
        switch entry {
        case .primary:
            return primarySubtitle
        case .ccpmProfile(let profile):
            return ccpmSubtitle(profile, index: index)
        }
    }

    private var primarySubtitle: String {
        var parts = [tr("Default", "默认")]
        if !SettingsStore.shared.privacyMode,
           let email = appState.claudeAccount?.email,
           !email.isEmpty {
            parts.append(email)
        }
        if let plan = appState.claudeAccount?.subscriptionType, !plan.isEmpty {
            parts.append(plan.capitalized)
        }
        return parts.joined(separator: " · ")
    }

    private func ccpmSubtitle(_ profile: CCPMClaudeProfile, index: Int) -> String {
        var parts = ["ccpm"]
        if SettingsStore.shared.privacyMode {
            parts.append(tr("Profile \(index + 1)", "账号 \(index + 1)"))
        } else {
            parts.append(profileDisplayName(profile))
            if let email = profile.email, !email.isEmpty {
                parts.append(email)
            }
        }
        if profile.isDefault {
            parts.append("Default")
        }
        if let plan = profile.organizationType, !plan.isEmpty {
            parts.append(plan.replacingOccurrences(of: "_", with: " ").capitalized)
        }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func profileDisplayName(_ profile: CCPMClaudeProfile) -> String {
        if let displayName = profile.displayName, !displayName.isEmpty {
            return displayName
        }
        return profile.name
    }

    private func snapshot(for entry: ClaudeMonitorEntry) -> QuotaSnapshot? {
        switch entry {
        case .primary:
            return appState.claudeQuota
        case .ccpmProfile(let profile):
            return appState.ccpmClaudeQuota(for: profile)
        }
    }

    private func error(for entry: ClaudeMonitorEntry) -> String? {
        switch entry {
        case .primary:
            return appState.claudeQuotaError
        case .ccpmProfile(let profile):
            return appState.ccpmClaudeError(for: profile)
        }
    }

    private func weekSpend(for entry: ClaudeMonitorEntry) -> Decimal? {
        switch entry {
        case .primary:
            let (from, to) = Self.weekBounds()
            return appState.usageService.aggregator.totals(app: .claude, from: from, to: to).costUSD
        case .ccpmProfile:
            return nil
        }
    }

    private func todayCost(for entry: ClaudeMonitorEntry) -> Decimal? {
        switch entry {
        case .primary:
            return appState.claudeTodayCost
        case .ccpmProfile:
            return nil
        }
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

private enum ClaudeMonitorEntry: Identifiable {
    case primary
    case ccpmProfile(CCPMClaudeProfile)

    var id: String {
        switch self {
        case .primary:
            return "primary"
        case .ccpmProfile(let profile):
            return "ccpm:\(profile.id)"
        }
    }
}
