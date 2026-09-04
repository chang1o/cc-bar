import SwiftUI

// MARK: - FloatingContentView
//
// Always-on-top pill: one row per provider enabled for the HUD.
// Row: 18pt ServiceTile + flexible 4pt bar + lane label + 34pt percent.

struct FloatingContentView: View {
    @Environment(AppState.self) private var appState
    let settings: SettingsStore

    var body: some View {
        let present = appState.presentProviders
        let providers = settings.effectiveFloatingProviders.filter { present.contains($0) }
        let choice = settings.menuBarWindow

        VStack(alignment: .leading, spacing: 7) {
            ForEach(providers, id: \.self) { provider in
                let snapshot = appState.monitorSnapshot(for: provider)
                let window = Self.laneWindow(snapshot, choice: choice)
                FloatingRow(
                    provider: provider,
                    label: window?.kind.shortLabel ?? Self.laneKind(provider, choice: choice).shortLabel,
                    window: window
                )
            }
            if providers.isEmpty {
                Text(tr("No services", "未启用"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minWidth: 190, alignment: .leading)
        .background {
            // Solid layer + popover material + hairline: keeps the HUD legible on busy wallpapers.
            ZStack {
                Color(nsColor: .windowBackgroundColor).opacity(0.55)
                VisualEffectBackground(material: .popover, blendingMode: .behindWindow)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
        )
        .fixedSize()
    }

    private static func laneWindow(_ snapshot: QuotaSnapshot?, choice: MenuBarWindowChoice) -> QuotaWindow? {
        switch choice {
        case .primary, .both:
            return snapshot?.primary
        case .secondary:
            return snapshot?.secondary ?? snapshot?.primary
        }
    }

    private static func laneKind(_ provider: Provider, choice: MenuBarWindowChoice) -> QuotaWindowKind {
        let descriptor = provider.descriptor
        switch choice {
        case .primary, .both: return descriptor.primaryKind
        case .secondary: return descriptor.secondaryKind ?? descriptor.primaryKind
        }
    }
}

private struct FloatingRow: View {
    let provider: Provider
    let label: String
    let window: QuotaWindow?

    var body: some View {
        HStack(spacing: 8) {
            ServiceTile(
                logoName: provider.logoName,
                fallback: provider.descriptor.fallbackGlyph,
                tint: provider.accent,
                size: 18,
                logoSize: 12,
                cornerRadius: 5
            )

            ProgressBar(value: barValue, tint: barColor, height: 4)
                .frame(minWidth: 56)

            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.quaternary)
                .frame(width: 22, alignment: .trailing)

            Text(percentText)
                .font(.system(size: 13, weight: .semibold))
                .kerning(-0.3)
                .monospacedDigit()
                .foregroundStyle(barColor)
                .frame(minWidth: 34, alignment: .trailing)
        }
    }

    private var barValue: Double {
        guard let window else { return 0 }
        return window.remainingPercent / 100
    }

    private var percentText: String {
        guard let window else { return "--%" }
        return "\(Int(window.remainingPercent.rounded()))%"
    }

    private var barColor: Color {
        statusColor(remainingPercent: window?.remainingPercent, tint: provider.accent)
    }
}
