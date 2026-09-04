import SwiftUI
import AppKit

struct MenuBarLabel: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let settings = SettingsStore.shared
        let items = menuBarItems
        Image(nsImage: MenuBarBadgeImage.make(items: items, style: settings.menuBarStyle))
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityLabel(MenuBarBadgeImage.accessibilityLabel(items: items))
    }

    /// One segment per provider that is present and switched on for the bar. The value
    /// is the most constrained account of that provider; `lowestOnly` keeps just the
    /// provider with the least headline quota left.
    private var menuBarItems: [MenuBarBadgeItem] {
        let settings = SettingsStore.shared
        let present = appState.presentProviders
        let providers = QuotaProviderDescriptor.menuBarProviders.filter {
            present.contains($0.app) && settings.effectiveMenuBarVisibility(for: $0.app)
        }
        var items = providers.map { provider -> MenuBarBadgeItem in
            let snapshot = appState.monitorSnapshot(for: provider.app)
            let limits = snapshot.map {
                MenuBarQuotaSelection.limits(in: $0, choice: settings.menuBarWindow)
            } ?? []
            return MenuBarBadgeItem(
                descriptor: provider,
                isUnlimited: snapshot?.isUnlimited == true,
                remaining: limits.map(\.window.remainingPercent)
            )
        }
        if settings.menuBarMode == .lowestOnly, items.count > 1 {
            let withData = items.filter { $0.headlineRemaining != nil }
            let lowest = withData.min { ($0.headlineRemaining ?? 101) < ($1.headlineRemaining ?? 101) }
            items = [lowest ?? items[0]]
        }
        return items
    }
}

struct MenuBarBadgeItem {
    let descriptor: QuotaProviderDescriptor
    let isUnlimited: Bool
    /// Remaining percent of the selected lanes, headline lane first (0–2 entries).
    let remaining: [Double]

    var headlineRemaining: Double? {
        isUnlimited ? 100 : remaining.first
    }

    var text: String {
        if isUnlimited { return "∞" }
        guard !remaining.isEmpty else { return "--" }
        return remaining.map { "\(Int($0.rounded()))%" }.joined(separator: "/")
    }

    /// Fill levels for the meter style; unlimited draws one full meter.
    var meterLevels: [Double?] {
        if isUnlimited { return [100] }
        return remaining.isEmpty ? [nil] : remaining
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
    private static let meterWidth: CGFloat = 5
    private static let meterHeight: CGFloat = 14
    private static let meterGap: CGFloat = 2
    private static let font = NSFont.monospacedDigitSystemFont(
        ofSize: NSFont.menuBarFont(ofSize: 0).pointSize,
        weight: .regular
    )

    static func make(items: [MenuBarBadgeItem], style: MenuBarStyle = .percent) -> NSImage {
        // 没有任何 item 时仍要返回一个最小图像（至少留一个 logo 占位以免菜单栏图标完全消失）
        if items.isEmpty {
            return placeholderImage()
        }

        let attrs = textAttributes
        var width: CGFloat = 0
        for (index, item) in items.enumerated() {
            if index > 0 { width += segmentGap }
            width += segmentWidth(item, style: style, attrs: attrs)
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
            switch style {
            case .percent:
                if !item.text.isEmpty {
                    x += iconTextGap
                    let textSize = item.text.size(withAttributes: attrs)
                    item.text.draw(at: NSPoint(x: x, y: floor((height - textSize.height) / 2)),
                                   withAttributes: attrs)
                    x += ceil(textSize.width)
                }
            case .meter:
                x += iconTextGap
                for (meterIndex, level) in item.meterLevels.enumerated() {
                    if meterIndex > 0 { x += meterGap }
                    drawMeter(remaining: level, x: x)
                    x += meterWidth
                }
            }
        }

        image.unlockFocus()
        image.isTemplate = true
        return image
    }

    private static func segmentWidth(
        _ item: MenuBarBadgeItem,
        style: MenuBarStyle,
        attrs: [NSAttributedString.Key: Any]
    ) -> CGFloat {
        switch style {
        case .percent:
            let textPart = item.text.isEmpty ? 0 : iconTextGap + ceil(item.text.size(withAttributes: attrs).width)
            return iconSize + textPart
        case .meter:
            let count = CGFloat(item.meterLevels.count)
            return iconSize + iconTextGap + meterWidth * count + meterGap * (count - 1)
        }
    }

    static func accessibilityLabel(items: [MenuBarBadgeItem]) -> String {
        let parts = items.map { item in
            item.isUnlimited
                ? "\(item.descriptor.title) Unlimited"
                : "\(item.descriptor.title) \(item.text)"
        }
        return parts.isEmpty ? "CCBar" : parts.joined(separator: ", ")
    }

    private static var textAttributes: [NSAttributedString.Key: Any] {
        [
            .font: font,
            .foregroundColor: NSColor.black
        ]
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

    private static func drawIcon(_ item: MenuBarBadgeItem, x: CGFloat) {
        let rect = NSRect(x: x, y: floor((height - iconSize) / 2), width: iconSize, height: iconSize)
        if let img = MenuBarLogo.rawImage(named: item.descriptor.logoName) {
            img.draw(in: rect)
            return
        }

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9, weight: .semibold),
            .foregroundColor: NSColor.black
        ]
        let glyph = item.descriptor.fallback
        let size = glyph.size(withAttributes: attrs)
        glyph.draw(at: NSPoint(x: x + floor((iconSize - size.width) / 2),
                               y: floor((height - size.height) / 2)),
                   withAttributes: attrs)
    }

    /// Vertical meter: 1px outline, filled from the bottom by remaining percent.
    /// Missing data draws the empty outline so the segment keeps its width.
    private static func drawMeter(remaining: Double?, x: CGFloat) {
        let frame = NSRect(x: x, y: floor((height - meterHeight) / 2), width: meterWidth, height: meterHeight)
        let outline = NSBezierPath(roundedRect: frame.insetBy(dx: 0.5, dy: 0.5), xRadius: 1, yRadius: 1)
        outline.lineWidth = 1
        NSColor.black.withAlphaComponent(0.55).setStroke()
        outline.stroke()

        guard let remaining, remaining > 0 else { return }
        let fraction = max(0, min(1, remaining / 100))
        let inner = frame.insetBy(dx: 1, dy: 1)
        let fillHeight = max(1, round(inner.height * fraction))
        let fill = NSRect(x: inner.minX, y: inner.minY, width: inner.width, height: fillHeight)
        NSColor.black.setFill()
        NSBezierPath(roundedRect: fill, xRadius: 0.5, yRadius: 0.5).fill()
    }
}

enum MenuBarQuotaSelection {
    static func limits(
        in snapshot: QuotaSnapshot,
        choice: MenuBarWindowChoice
    ) -> [QuotaLimit] {
        // Cursor 的 Total / Auto / API 是同一计费周期下的不同额度维度，
        // 不是主 / 周窗口。菜单栏只显示 Total，避免把 Auto 伪装成 Weekly，
        // 也避免三段数字挤占菜单栏空间；明细始终在 Popover 展示。
        if snapshot.app == .cursor {
            return [snapshot.primaryLimit].compactMap { $0 }
        }
        switch choice {
        case .primary:
            return [snapshot.primaryLimit].compactMap { $0 }
        case .weekly:
            // Providers without a weekly lane (single-window plans) fall back to primary
            // instead of going blank.
            return [snapshot.weeklyLimit ?? snapshot.primaryLimit].compactMap { $0 }
        case .both:
            return [snapshot.primaryLimit, snapshot.secondaryLimit]
                .compactMap { $0 }
                .reduce(into: [QuotaLimit]()) { result, limit in
                    if !result.contains(where: { $0.id == limit.id }) { result.append(limit) }
                }
        }
    }
}
