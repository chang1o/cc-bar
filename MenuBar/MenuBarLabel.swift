import SwiftUI
import AppKit

struct MenuBarLabel: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let claudeQuota = appState.claudeMonitorQuota()
        Image(nsImage: MenuBarBadgeImage.make(
            codex: appState.codexQuota,
            claude: claudeQuota,
            showCodex: SettingsStore.shared.effectiveMenuBarShowCodex,
            showClaude: SettingsStore.shared.effectiveMenuBarShowClaude,
            window: SettingsStore.shared.menuBarWindow
        ))
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityLabel(MenuBarBadgeImage.accessibilityLabel(
            codex: appState.codexQuota,
            claude: claudeQuota,
            showCodex: SettingsStore.shared.effectiveMenuBarShowCodex,
            showClaude: SettingsStore.shared.effectiveMenuBarShowClaude,
            window: SettingsStore.shared.menuBarWindow
        ))
    }
}

enum MenuBarLogo {
    private static let cache = NSCache<NSString, NSImage>()
    private static let size = NSSize(width: 18, height: 18)

    static func rawImage(named name: String) -> NSImage? {
        if let cached = cache.object(forKey: name as NSString) { return cached }
        guard let url = Bundle.main.url(forResource: name, withExtension: "svg"),
              let img = NSImage(contentsOf: url) else { return nil }
        img.size = size
        cache.setObject(img, forKey: name as NSString)
        return img
    }
}

enum MenuBarBadgeImage {
    private static let iconSize: CGFloat = 18
    private static let height: CGFloat = 22
    private static let iconTextGap: CGFloat = 3
    private static let segmentGap: CGFloat = 9
    private static let font = NSFont.monospacedDigitSystemFont(
        ofSize: NSFont.menuBarFont(ofSize: 0).pointSize,
        weight: .regular
    )

    static func make(
        codex: QuotaSnapshot?,
        claude: QuotaSnapshot?,
        showCodex: Bool,
        showClaude: Bool,
        window: MenuBarWindowChoice
    ) -> NSImage {
        var items: [BadgeItem] = []
        if showCodex {
            items.append(BadgeItem(logo: "codex", fallback: "C", text: pctText(codex, window: window)))
        }
        if showClaude {
            items.append(BadgeItem(logo: "claude", fallback: "K", text: pctText(claude, window: window)))
        }

        let attrs = textAttributes
        let textWidths = items.map { $0.text.size(withAttributes: attrs).width }
        let width = items.enumerated().reduce(CGFloat.zero) { partial, entry in
            let gap = entry.offset == 0 ? CGFloat.zero : segmentGap
            let textPart = entry.element.text.isEmpty ? 0 : iconTextGap + ceil(textWidths[entry.offset])
            return partial + gap + iconSize + textPart
        }

        // 没有任何 item 时仍要返回一个最小图像（至少留一个 logo 占位以免菜单栏图标完全消失）
        if items.isEmpty {
            return placeholderImage()
        }

        let image = NSImage(size: NSSize(width: max(ceil(width), iconSize), height: height))
        image.lockFocus()
        NSColor.clear.setFill()
        NSRect(origin: .zero, size: image.size).fill()

        var x: CGFloat = 0
        for (index, item) in items.enumerated() {
            if index > 0 { x += segmentGap }
            drawIcon(item, x: x)
            x += iconSize
            if !item.text.isEmpty {
                x += iconTextGap
                let textSize = item.text.size(withAttributes: attrs)
                item.text.draw(at: NSPoint(x: x, y: floor((height - textSize.height) / 2)),
                               withAttributes: attrs)
                x += ceil(textSize.width)
            }
        }

        image.unlockFocus()
        image.isTemplate = true
        return image
    }

    static func accessibilityLabel(
        codex: QuotaSnapshot?,
        claude: QuotaSnapshot?,
        showCodex: Bool,
        showClaude: Bool,
        window: MenuBarWindowChoice
    ) -> String {
        var parts: [String] = []
        if showCodex { parts.append("Codex \(pctText(codex, window: window))") }
        if showClaude { parts.append("Claude \(pctText(claude, window: window))") }
        return parts.isEmpty ? "CCBar" : parts.joined(separator: ", ")
    }

    private static var textAttributes: [NSAttributedString.Key: Any] {
        [
            .font: font,
            .foregroundColor: NSColor.black
        ]
    }

    private static func pctText(_ snap: QuotaSnapshot?, window: MenuBarWindowChoice) -> String {
        switch window {
        case .fiveHour:
            return pctOrPlaceholder(snap?.fiveHour)
        case .weekly:
            return pctOrPlaceholder(snap?.weekly)
        case .both:
            let a = pctOrPlaceholder(snap?.fiveHour)
            let b = pctOrPlaceholder(snap?.weekly)
            return "\(a)/\(b)"
        }
    }

    private static func pctOrPlaceholder(_ window: QuotaWindow?) -> String {
        guard let window else { return "--" }
        return "\(Int(window.remainingPercent.rounded()))%"
    }

    private static func placeholderImage() -> NSImage {
        let image = NSImage(size: NSSize(width: iconSize, height: height))
        image.lockFocus()
        NSColor.clear.setFill()
        NSRect(origin: .zero, size: image.size).fill()
        if let img = MenuBarLogo.rawImage(named: "codex") {
            img.draw(in: NSRect(x: 0, y: floor((height - iconSize) / 2),
                                width: iconSize, height: iconSize))
        }
        image.unlockFocus()
        image.isTemplate = true
        return image
    }

    private static func drawIcon(_ item: BadgeItem, x: CGFloat) {
        let rect = NSRect(x: x, y: floor((height - iconSize) / 2), width: iconSize, height: iconSize)
        if let img = MenuBarLogo.rawImage(named: item.logo) {
            img.draw(in: rect)
            return
        }

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9, weight: .semibold),
            .foregroundColor: NSColor.black
        ]
        let size = item.fallback.size(withAttributes: attrs)
        item.fallback.draw(at: NSPoint(x: x + floor((iconSize - size.width) / 2),
                                       y: floor((height - size.height) / 2)),
                           withAttributes: attrs)
    }

    private struct BadgeItem {
        let logo: String
        let fallback: String
        let text: String
    }
}
