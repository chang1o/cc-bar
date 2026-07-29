import SwiftUI

struct CCPMCodexProfilesView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        if appState.ccpmCodexProfiles.isEmpty {
            CCPMProfilesEmptyState()
        } else {
            VStack(spacing: 0) {
                ForEach(Array(appState.ccpmCodexProfiles.enumerated()), id: \.element.id) { index, profile in
                    if index > 0 { Divider().padding(.leading, 42) }
                    profileRow(profile)
                }
            }
        }
    }

    private func profileRow(_ profile: CCPMCodexProfile) -> some View {
        HStack(spacing: 10) {
            ServiceTile(
                logoName: "codex",
                fallback: "C",
                tint: .codexAccent,
                size: 26,
                logoSize: 16,
                cornerRadius: 7
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(profileTitle(profile))
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                Text(profileDetail(profile))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(profile.authMethod.rawValue)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(profile.authMethod == .oauth ? .secondary : .tertiary)
                if let snapshot = appState.ccpmCodexQuota(for: profile),
                   let remaining = snapshot.fiveHour?.remainingPercent {
                    Text("\(Int(remaining.rounded()))%")
                        .font(.system(size: 12, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(statusColor(remainingPercent: remaining, tint: .codexAccent))
                } else if appState.ccpmCodexRefreshState(for: profile).inFlight {
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
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private func profileTitle(_ profile: CCPMCodexProfile) -> String {
        if SettingsStore.shared.privacyMode { return profile.name }
        if let email = profile.email, !email.isEmpty {
            return "\(profile.name) · \(email.components(separatedBy: "@").first ?? email)"
        }
        return profile.name
    }

    private func profileDetail(_ profile: CCPMCodexProfile) -> String {
        if SettingsStore.shared.privacyMode { return profile.dir }
        var parts: [String] = []
        if let email = profile.email, !email.isEmpty { parts.append(email) }
        if let plan = profile.planType, !plan.isEmpty { parts.append(plan.capitalized) }
        parts.append(profile.dir)
        return parts.joined(separator: " · ")
    }
}

struct CCPMClaudeProfilesView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        if appState.ccpmClaudeProfiles.isEmpty {
            CCPMProfilesEmptyState()
        } else {
            VStack(spacing: 0) {
                ForEach(Array(appState.ccpmClaudeProfiles.enumerated()), id: \.element.id) { idx, profile in
                    if idx > 0 { Divider().padding(.leading, 42) }
                    profileRow(profile)
                }
            }
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
                Text("~/.ccpm/config.json")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

private extension CCPMClaudeProfilesView {
    func profileRow(_ profile: CCPMClaudeProfile) -> some View {
        HStack(spacing: 10) {
            ServiceTile(
                logoName: "claude",
                fallback: "K",
                tint: .claudeAccent,
                size: 26,
                logoSize: 16,
                cornerRadius: 7
            )

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(profileTitle(profile))
                        .font(.system(size: 12.5, weight: .medium))
                        .lineLimit(1)
                    if profile.isDefault {
                        Text("Default")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.12), in: Capsule())
                    }
                }
                Text(profileDetail(profile))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(profile.authMethod.rawValue)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(profile.authMethod == .oauth ? .secondary : .tertiary)
                if let snapshot = appState.ccpmClaudeQuota(for: profile),
                   let remaining = snapshot.fiveHour?.remainingPercent {
                    Text("\(Int(remaining.rounded()))%")
                        .font(.system(size: 12, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(statusColor(remainingPercent: remaining, tint: .claudeAccent))
                } else if appState.ccpmClaudeRefreshState(for: profile).inFlight {
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
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    func profileTitle(_ profile: CCPMClaudeProfile) -> String {
        if SettingsStore.shared.privacyMode { return profile.name }
        if let displayName = profile.displayName, !displayName.isEmpty {
            return "\(profile.name) · \(displayName)"
        }
        return profile.name
    }

    func profileDetail(_ profile: CCPMClaudeProfile) -> String {
        if SettingsStore.shared.privacyMode {
            return profile.dir
        }
        var parts: [String] = []
        if let email = profile.email, !email.isEmpty { parts.append(email) }
        if let org = profile.organizationType, !org.isEmpty {
            parts.append(org.replacingOccurrences(of: "_", with: " ").capitalized)
        }
        parts.append(profile.dir)
        return parts.joined(separator: " · ")
    }
}
