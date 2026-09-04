import SwiftUI
import AppKit

struct MenuBarLabel: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let settings = SettingsStore.shared
        let items = menuBarItems
        Image(nsImage: MenuBarBadgeImage.make(items: items, style: settings.menuBarStyle, window: settings.menuBarWindow))
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityLabel(MenuBarBadgeImage.accessibilityLabel(items: items))
    }

    /// One segment per provider that is enabled, present and switched on for
    /// the bar; `lowestOnly` keeps just the most constrained one.
    private var menuBarItems: [MenuBarBadgeItem] {
        let settings = SettingsStore.shared
        let present = appState.presentProviders
        let providers = settings.effectiveMenuBarProviders.filter { present.contains($0) }
        let window = settings.menuBarWindow
        var items = providers.map { provider -> MenuBarBadgeItem in
            let snapshot = appState.monitorSnapshot(for: provider)
            return MenuBarBadgeItem(
                provider: provider,
                text: MenuBarBadgeImage.percentText(snapshot, window: window),
                remaining: MenuBarBadgeImage.headlineRemaining(snapshot, window: window),
                secondaryRemaining: MenuBarBadgeImage.secondaryRemaining(snapshot, window: window)
            )
        }
        if settings.menuBarMode == .lowestOnly, items.count > 1 {
            let withData = items.filter { $0.remaining != nil }
            if let lowest = withData.min(by: { ($0.remaining ?? 101) < ($1.remaining ?? 101) }) {
                items = [lowest]
            } else {
                items = [items[0]]
            }
        }
        return items
    }
}

struct MenuBarBadgeItem {
    let provider: Provider
    let text: String
    let remaining: Double?
    /// Filled only for `MenuBarWindowChoice.both`; drives the second meter bar.
    let secondaryRemaining: Double?
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

    static func make(items: [MenuBarBadgeItem], style: MenuBarStyle = .percent, window: MenuBarWindowChoice = .primary) -> NSImage {
        if items.isEmpty {
            return placeholderImage()
        }

        let attrs = textAttributes
        let widths = items.map { segmentWidth($0, style: style, window: window, attrs: attrs) }
        let width = widths.enumerated().reduce(CGFloat.zero) { partial, entry in
            partial + (entry.offset == 0 ? 0 : segmentGap) + entry.element
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
                drawMeter(remaining: item.remaining, x: x)
                x += meterWidth
                if window == .both {
                    x += meterGap
                    drawMeter(remaining: item.secondaryRemaining, x: x)
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
        window: MenuBarWindowChoice,
        attrs: [NSAttributedString.Key: Any]
    ) -> CGFloat {
        switch style {
        case .percent:
            let textPart = item.text.isEmpty ? 0 : iconTextGap + ceil(item.text.size(withAttributes: attrs).width)
            return iconSize + textPart
        case .meter:
            let meters = window == .both ? meterWidth * 2 + meterGap : meterWidth
            return iconSize + iconTextGap + meters
        }
    }

    static func accessibilityLabel(items: [MenuBarBadgeItem]) -> String {
        let parts = items.map { "\($0.provider.displayName) \($0.text)" }
        return parts.isEmpty ? "CCBar" : parts.joined(separator: ", ")
    }

    private static var textAttributes: [NSAttributedString.Key: Any] {
        [
            .font: font,
            .foregroundColor: NSColor.black
        ]
    }

    static func percentText(_ snapshot: QuotaSnapshot?, window: MenuBarWindowChoice) -> String {
        switch window {
        case .primary:
            return pctOrPlaceholder(snapshot?.primary)
        case .secondary:
            return pctOrPlaceholder(snapshot?.secondary ?? snapshot?.primary)
        case .both:
            return "\(pctOrPlaceholder(snapshot?.primary))/\(pctOrPlaceholder(snapshot?.secondary))"
        }
    }

    static func headlineRemaining(_ snapshot: QuotaSnapshot?, window: MenuBarWindowChoice) -> Double? {
        guard let snapshot else { return nil }
        switch window {
        case .primary, .both: return snapshot.primary?.remainingPercent
        case .secondary: return (snapshot.secondary ?? snapshot.primary)?.remainingPercent
        }
    }

    /// The other lane, used only by the `both` display when drawing two meters.
    static func secondaryRemaining(_ snapshot: QuotaSnapshot?, window: MenuBarWindowChoice) -> Double? {
        guard let snapshot, window == .both else { return nil }
        return snapshot.secondary?.remainingPercent
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

    private static func drawIcon(_ item: MenuBarBadgeItem, x: CGFloat) {
        let rect = NSRect(x: x, y: floor((height - iconSize) / 2), width: iconSize, height: iconSize)
        if let img = MenuBarLogo.rawImage(named: item.provider.logoName) {
            img.draw(in: rect)
            return
        }

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9, weight: .semibold),
            .foregroundColor: NSColor.black
        ]
        let glyph = item.provider.descriptor.fallbackGlyph
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
