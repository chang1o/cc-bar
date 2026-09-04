import SwiftUI

/// Read-only list of every ccpm profile cc-bar discovered, across providers.
/// Ollama Cloud rows expose the cookie paste sheet.
struct CCPMProfilesView: View {
    @Environment(AppState.self) private var appState
    @State private var cookieTarget: MonitoredAccount?

    private var profiles: [MonitoredAccount] {
        appState.accounts.filter {
            if case .ccpm = $0.source { return true }
            return false
        }
    }

    var body: some View {
        let rows = profiles
        Group {
            if rows.isEmpty {
                CCPMProfilesEmptyState()
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, account in
                        if index > 0 { Divider().padding(.leading, 42) }
                        profileRow(account)
                    }
                }
            }
        }
        .sheet(item: $cookieTarget) { account in
            OllamaCookieSheet(account: account)
        }
    }

    private func profileRow(_ account: MonitoredAccount) -> some View {
        let state = appState.quotaState(for: account)
        let descriptor = account.descriptor
        return HStack(spacing: 10) {
            ServiceTile(
                logoName: descriptor.logoName,
                fallback: descriptor.fallbackGlyph,
                tint: account.provider.accent,
                size: 26,
                logoSize: 16,
                cornerRadius: 7
            )

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title(account))
                        .font(.system(size: 12.5, weight: .medium))
                        .lineLimit(1)
                    if account.identity.isDefaultProfile {
                        Text("Default")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.12), in: Capsule())
                    }
                }
                Text(detail(account, state: state))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            if account.provider == .ollama {
                Button {
                    cookieTarget = account
                } label: {
                    Text(hasCookie(account) ? tr("Cookie…", "Cookie…") : tr("Paste cookie…", "粘贴 Cookie…"))
                        .font(.system(size: 11))
                }
                .controlSize(.small)
            }

            VStack(alignment: .trailing, spacing: 2) {
                Text(credentialLabel(account))
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                if let snapshot = state.snapshot, let remaining = snapshot.primary?.remainingPercent {
                    Text("\(Int(remaining.rounded()))%")
                        .font(.system(size: 12, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(statusColor(remainingPercent: remaining, tint: account.provider.accent))
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
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private func title(_ account: MonitoredAccount) -> String {
        let name = account.identity.profileName ?? account.id.raw
        if SettingsStore.shared.privacyMode { return "\(account.descriptor.displayName) · \(name)" }
        if let displayName = account.identity.displayName, !displayName.isEmpty {
            return "\(account.descriptor.displayName) · \(name) · \(displayName)"
        }
        if let email = account.identity.email, !email.isEmpty {
            return "\(account.descriptor.displayName) · \(name) · \(email.components(separatedBy: "@").first ?? email)"
        }
        return "\(account.descriptor.displayName) · \(name)"
    }

    private func detail(_ account: MonitoredAccount, state: AccountQuotaState) -> String {
        if let error = state.error, !error.isEmpty, state.snapshot == nil {
            return error
        }
        if SettingsStore.shared.privacyMode { return account.identity.profileDir ?? "" }
        var parts: [String] = []
        if let email = account.identity.email, !email.isEmpty { parts.append(email) }
        if let plan = account.identity.plan, !plan.isEmpty { parts.append(plan) }
        switch account.credential {
        case .apiKey(_, let baseURL), .ollamaCookie(_, let baseURL):
            if let host = baseURL.host { parts.append(host) }
        default:
            break
        }
        if let dir = account.identity.profileDir { parts.append(dir) }
        return parts.joined(separator: " · ")
    }

    private func credentialLabel(_ account: MonitoredAccount) -> String {
        switch account.credential {
        case .codexOAuth, .claudeOAuth: return "oauth"
        case .apiKey: return "api_key"
        case .ollamaCookie(let cookie, _): return cookie == nil ? tr("no cookie", "无 Cookie") : "cookie"
        case .unavailable: return tr("unavailable", "不可用")
        }
    }

    private func hasCookie(_ account: MonitoredAccount) -> Bool {
        if case .ollamaCookie(let cookie, _) = account.credential { return cookie != nil }
        return false
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

// MARK: - Ollama cookie sheet

private struct OllamaCookieSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    let account: MonitoredAccount
    @State private var text: String = ""
    @State private var error: String?

    private var profile: String {
        if case .ccpm(let name) = account.source { return name }
        return account.identity.profileName ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(tr("Ollama Cloud cookie", "Ollama Cloud Cookie"))
                .font(.system(size: 14, weight: .semibold))
            Text(tr(
                "Sign in at ollama.com, open DevTools → Network, copy the Cookie request header of any ollama.com request and paste it here. It is stored in your login Keychain and only sent to ollama.com/settings.",
                "登录 ollama.com 后打开开发者工具 → Network,复制任意 ollama.com 请求的 Cookie 请求头粘贴到这里。它保存在你的登录钥匙串中,只会发送到 ollama.com/settings。"
            ))
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            TextEditor(text: $text)
                .font(.system(size: 11, design: .monospaced))
                .frame(minHeight: 120)
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 0.5)
                )

            if let error {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            }

            HStack {
                Button(tr("Remove", "移除"), role: .destructive) {
                    OllamaCookieStore.delete(profile: profile)
                    Task { await appState.rediscover() }
                    dismiss()
                }
                .disabled(profile.isEmpty)
                Spacer()
                Button(tr("Cancel", "取消")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(tr("Save", "保存")) { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear {
            if case .ollamaCookie(let cookie, _) = account.credential, let cookie {
                text = cookie
            }
        }
    }

    private func save() {
        do {
            try appState.setOllamaCookie(text, profile: profile)
            dismiss()
        } catch {
            self.error = "\(error)"
        }
    }
}
