import SwiftUI

/// Read-only list of every ccpm profile cc-bar discovered, across providers.
struct CCPMProfilesView: View {
    @Environment(AppState.self) private var appState
    @State private var binaryPath: String?
    @State private var binaryResolved = false
    @State private var isRediscovering = false

    var body: some View {
        let accounts = appState.ccpmAccounts
        VStack(spacing: 0) {
            toolbarRow
            Divider().padding(.leading, 14)
            if accounts.isEmpty {
                CCPMProfilesEmptyState()
            } else {
                ForEach(Array(accounts.enumerated()), id: \.element.id) { index, account in
                    if index > 0 { Divider().padding(.leading, 48) }
                    profileRow(account)
                }
            }
        }
        .task {
            // `resolveBinary` may spawn a login shell; keep it off the main actor.
            let path = await Task.detached(priority: .utility) { CCPMCommand.resolveBinary() }.value
            binaryPath = path
            binaryResolved = true
        }
    }

    private var toolbarRow: some View {
        HStack(spacing: 10) {
            Image(systemName: binaryPath == nil ? "terminal" : "terminal.fill")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(binaryStatusTitle)
                    .font(.system(size: 12))
                Text(binaryPath ?? "~/.ccpm/config.json")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button {
                isRediscovering = true
                Task {
                    await appState.rediscoverCCPMAccounts()
                    isRediscovering = false
                }
            } label: {
                if isRediscovering {
                    ProgressView().controlSize(.small)
                } else {
                    Text(tr("Rediscover", "重新发现"))
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(isRediscovering)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private var binaryStatusTitle: String {
        guard binaryResolved else { return tr("Looking for ccpm…", "正在查找 ccpm…") }
        return binaryPath == nil
            ? tr("ccpm not found in PATH · Terminal / Set default unavailable", "未找到 ccpm · 终端与设为默认不可用")
            : tr("ccpm found", "已找到 ccpm")
    }

    private func profileRow(_ account: CCPMAccount) -> some View {
        let state = appState.ccpmQuotaState(for: account)
        let descriptor = account.app.descriptor
        return HStack(spacing: 10) {
            ServiceTile(
                logoName: descriptor.logoName,
                fallback: descriptor.fallback,
                tint: account.app.tintColor,
                size: 26,
                logoSize: 16,
                cornerRadius: 7
            )

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title(account))
                        .font(.system(size: 12.5, weight: .medium))
                        .lineLimit(1)
                    if account.profile.isDefault {
                        badge(tr("Default", "默认"))
                    }
                    if account.mirrorsPrimary {
                        badge(tr("Same as primary", "与主账号相同"))
                    }
                }
                Text(detail(account, state: state))
                    .font(.system(size: 11))
                    .foregroundStyle(detailIsError(account, state: state) ? Color.orange : Color.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(credentialLabel(account))
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                remainingView(account, state: state)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    @ViewBuilder
    private func remainingView(_ account: CCPMAccount, state: PrimaryQuotaState) -> some View {
        if let limit = state.snapshot?.primaryLimit {
            let remaining = limit.window.remainingPercent
            Text("\(Int(remaining.rounded()))%")
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(statusColor(remainingPercent: remaining, tint: account.app.tintColor))
        } else if state.refresh.inFlight {
            ProgressView()
                .scaleEffect(0.55)
                .frame(width: 14, height: 14)
        } else {
            Text("--")
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
        }
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Color.secondary.opacity(0.12), in: Capsule())
    }

    private func title(_ account: CCPMAccount) -> String {
        let base = "\(account.app.descriptor.title) · \(account.profile.name)"
        if SettingsStore.shared.privacyMode { return base }
        if let displayName = account.profile.displayName, !displayName.isEmpty, displayName != account.profile.name {
            return "\(base) · \(displayName)"
        }
        return base
    }

    private func detail(_ account: CCPMAccount, state: PrimaryQuotaState) -> String {
        if case .unavailable(let reason) = account.availability {
            return reason
        }
        if let error = state.error, !error.isEmpty, state.snapshot == nil {
            return error
        }
        if SettingsStore.shared.privacyMode { return account.profile.directory.path }
        var parts: [String] = []
        if let detail = account.detail, !detail.isEmpty { parts.append(detail) }
        if let plan = state.snapshot?.planType, !plan.isEmpty { parts.append(plan) }
        if let baseURL = account.profile.baseURL, let host = URL(string: baseURL)?.host,
           !parts.contains(host) {
            parts.append(host)
        }
        parts.append(account.profile.directory.path)
        return parts.joined(separator: " · ")
    }

    private func detailIsError(_ account: CCPMAccount, state: PrimaryQuotaState) -> Bool {
        if case .unavailable = account.availability { return true }
        return state.snapshot == nil && !(state.error ?? "").isEmpty
    }

    private func credentialLabel(_ account: CCPMAccount) -> String {
        switch account.app {
        case .kimi, .glm, .ollama:
            return "api_key"
        case .codex, .claude, .antigravity, .cursor, .commandCode:
            if case .unavailable = account.availability { return tr("unavailable", "不可用") }
            return account.profile.usesAPIKey ? "api_key" : "oauth"
        }
    }

}

private struct CCPMProfilesEmptyState: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "person.2.slash")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(tr("No ccpm profiles found", "未发现 ccpm profile"))
                    .font(.system(size: 12.5, weight: .medium))
                Text("ccpm add <name> --provider kimi|glm|ollama|codex")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}
