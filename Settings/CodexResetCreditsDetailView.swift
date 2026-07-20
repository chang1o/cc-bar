import SwiftUI

// MARK: - CodexResetCreditsDetailView
//
// 展开显示某个 Codex 账号的额外「Full reset」credit(rate-limit-reset-credits)明细。
// 主账号行(SettingsRootView)和导入账号行(ImportedCodexAccountsView)共用同一份 UI,
// 避免两处重复渲染。数据均为懒加载,不持久化。

/// 重置 credit 的加载状态。
enum CodexResetCreditsState {
    case loading
    case success(CodexResetCreditsClient.Fetched)
    case failure(String)
}

struct CodexResetCreditsDetailView: View {
    let state: CodexResetCreditsState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch state {
            case .loading:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(tr("Loading…", "加载中…"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            case .success(let fetched):
                Text(tr("\(fetched.availableCount) resets available", "可用额外重置 \(fetched.availableCount) 次"))
                    .font(.system(size: 11, weight: .semibold))
                if fetched.credits.isEmpty {
                    Text(tr("No records", "暂无记录"))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                } else {
                    ForEach(fetched.credits) { credit in
                        HStack(spacing: 6) {
                            Text(credit.title.isEmpty ? credit.status : credit.title)
                                .font(.system(size: 10.5))
                                .lineLimit(1)
                            Spacer()
                            if let expiresAt = credit.expiresAt {
                                Text(tr(
                                    "expires \(Self.dateFormatter.string(from: expiresAt))",
                                    "过期 \(Self.dateFormatter.string(from: expiresAt))"
                                ))
                                .font(.system(size: 9.5, design: .monospaced))
                                .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            case .failure(let message):
                Text(message)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 2)
        .padding(.bottom, 10)
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()
}
