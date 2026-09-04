import SwiftUI

/// One provider in the popover: every account renders as a full card; a
/// section header appears when there is more than one account.
struct ProviderSection: View {
    @Environment(AppState.self) private var appState
    let provider: Provider

    var body: some View {
        let accounts = appState.accounts(for: provider)
        if accounts.isEmpty {
            EmptyView()
        } else {
            VStack(spacing: 0) {
                if accounts.count > 1 {
                    ServiceAccountsSectionHeader(
                        title: "\(provider.displayName.uppercased()) ACCOUNTS",
                        chineseTitle: "\(provider.displayName) 账号",
                        count: accounts.count
                    )
                }
                ForEach(Array(accounts.enumerated()), id: \.element.id) { index, account in
                    if index > 0 {
                        Divider().padding(.horizontal, 16)
                    }
                    card(account, index: index)
                }
            }
        }
    }

    private func card(_ account: MonitoredAccount, index: Int) -> some View {
        let hasUsage = !account.usageRoots.isEmpty
        let aggregator = appState.usageService.aggregator
        let today = UsageDay.startOfDay(for: Date())
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: today) ?? today
        let (weekFrom, weekTo) = UsageWeek.bounds()
        let monthFrom = Calendar.current.date(byAdding: .day, value: -29, to: today) ?? today
        return ServiceBlockView(
            account: account,
            state: appState.quotaState(for: account),
            subtitle: account.popoverSubtitle(index: index),
            todayTotals: hasUsage ? aggregator.totals(accountId: account.id.raw, from: today, to: tomorrow) : nil,
            weekTotals: hasUsage ? aggregator.totals(accountId: account.id.raw, from: weekFrom, to: weekTo) : nil,
            monthTotals: hasUsage ? aggregator.totals(accountId: account.id.raw, from: monthFrom, to: tomorrow) : nil,
            serviceStatus: SettingsStore.shared.showServiceStatus ? appState.serviceStatus[provider] : nil,
            onProfilesChanged: { Task { await appState.rediscover() } }
        )
    }
}

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
