import SwiftUI

// MARK: - CCPMAccountsSection
//
// ccpm profiles of one provider inside its popover section. Profiles that share the
// primary account's identity collapse into a caption under the primary card (their
// logs count towards the primary card); every other profile is a full `ServiceBlockView`
// card (muted when it cannot be monitored) with the cost of its own log directory.

struct CCPMAccountsSection: View {
    @Environment(AppState.self) private var appState
    let app: QuotaApp
    /// True when a primary card was rendered above: mirrors attach to it and the first
    /// standalone card needs a divider.
    var hasPrecedingCard: Bool

    var body: some View {
        let accounts = appState.ccpmAccounts(for: app)
        let mirrors = accounts.filter(\.mirrorsPrimary)
        let standalone = accounts.filter { !$0.mirrorsPrimary }

        if accounts.isEmpty {
            EmptyView()
        } else {
            VStack(spacing: 0) {
                if hasPrecedingCard, !mirrors.isEmpty {
                    mirrorCaption(mirrors)
                }
                ForEach(Array(standalone.enumerated()), id: \.element.id) { index, account in
                    if hasPrecedingCard || index > 0 {
                        Divider().padding(.horizontal, 16)
                    }
                    card(account)
                }
            }
        }
    }

    private func mirrorCaption(_ mirrors: [CCPMAccount]) -> some View {
        let names = mirrors.map(\.profile.name).joined(separator: ", ")
        let label = mirrors.count == 1
            ? tr("Also used by ccpm profile \(names)", "ccpm profile \(names) 使用同一账号")
            : tr("Also used by ccpm profiles \(names)", "ccpm profiles \(names) 使用同一账号")
        return HStack(spacing: 5) {
            Image(systemName: "link")
                .font(.system(size: 9))
            Text(label)
                .font(.system(size: 10.5))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
        .padding(.top, -4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func card(_ account: CCPMAccount) -> some View {
        let descriptor = QuotaProviderDescriptor.descriptor(for: app)
        let state = appState.ccpmQuotaState(for: account)
        var reason: String?
        if case .unavailable(let text) = account.availability { reason = text }
        return ServiceBlockView(
            app: app,
            title: descriptor?.title ?? account.label,
            subtitle: subtitle(for: account),
            tint: app.tintColor,
            logoName: descriptor?.logoName ?? app.rawValue,
            fallback: descriptor?.fallback ?? "?",
            state: state,
            error: state.error,
            usage: usage(for: account),
            serviceStatus: nil,
            planBadge: ServiceBlockView.formatPlan(state.snapshot?.planType),
            dashboardURL: descriptor?.dashboardURL,
            statusPageURL: descriptor?.statusPageWebURL,
            ccpmAccount: account,
            unavailableReason: reason,
            onProfilesChanged: { Task { await appState.rediscoverCCPMAccounts() } }
        )
    }

    /// Cost scanned from the profile's own directory (`<profile>/projects` for Claude,
    /// `<profile>/sessions` for Codex); providers without local logs show no cost row.
    private func usage(for account: CCPMAccount) -> ServiceBlockView.Usage? {
        guard let descriptor = QuotaProviderDescriptor.descriptor(for: app),
              descriptor.showsCost,
              let usageApp = app.usageApp
        else { return nil }
        return PopoverRootView.localUsage(
            app: usageApp,
            account: .ccpm(account.profile.name),
            aggregator: appState.usageService.aggregator
        )
    }

    /// "ccpm · work · me@x.com · Default"; the identity part is dropped in privacy mode.
    private func subtitle(for account: CCPMAccount) -> String {
        var parts = ["ccpm", account.profile.name]
        if !SettingsStore.shared.privacyMode, let detail = account.detail, !detail.isEmpty {
            parts.append(detail)
        }
        if account.profile.isDefault {
            parts.append(tr("Default", "默认"))
        }
        return parts.joined(separator: " · ")
    }
}
