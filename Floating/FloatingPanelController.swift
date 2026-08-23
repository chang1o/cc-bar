import AppKit
import SwiftUI

@MainActor
final class FloatingPanelController: NSObject {
    static let shared = FloatingPanelController()

    private var panel: FloatingPanel?
    private var hostingView: NSHostingView<AnyView>?
    private weak var appState: AppState?
    private var observers: [NSObjectProtocol] = []
    private var snapTask: Task<Void, Never>?

    /// 默认窗口大小（实际大小由 SwiftUI fixedSize 收缩决定，这里只是初始 contentRect）
    private static let defaultSize = CGSize(width: 160, height: 64)
    private static let defaultMargin: CGFloat = 16
    /// 拖动到距屏幕边缘小于此阈值时自动吸附
    private static let snapThreshold: CGFloat = 20

    func attach(appState: AppState) {
        self.appState = appState
    }

    /// 根据当前设置同步显示 / 隐藏 / 行刷新
    func sync() {
        let settings = SettingsStore.shared
        if settings.floatingEnabled {
            show()
        } else {
            hide()
        }
    }

    private func show() {
        guard let appState else { return }
        if panel == nil {
            buildPanel(appState: appState)
        }
        resizeToFitContent()
        panel?.orderFrontRegardless()
    }

    /// 用 SwiftUI 的 fittingSize 调整 panel 尺寸，保持左上角不动。
    /// 立即同步一次；再在下一帧补一次，覆盖 SwiftUI view 异步重渲染的情况。
    private func resizeToFitContent() {
        applyFitOnce()
        Task { @MainActor [weak self] in
            self?.applyFitOnce()
        }
    }

    private func applyFitOnce() {
        guard let panel, let hosting = hostingView else { return }
        hosting.layoutSubtreeIfNeeded()
        let fit = hosting.fittingSize
        guard fit.width > 1, fit.height > 1 else { return }
        var frame = panel.frame
        let dh = fit.height - frame.height
        frame.origin.y -= dh
        frame.size = fit
        panel.setFrame(frame, display: true)
    }

    private func hide() {
        panel?.orderOut(nil)
    }

    private func buildPanel(appState: AppState) {
        let settings = SettingsStore.shared
        let content = AnyView(
            FloatingContentView(settings: settings)
                .environment(appState)
        )
        let hosting = DraggableHostingView(rootView: content)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        // hosting view 的 layer 默认会用系统底色填满矩形 content,会在 SwiftUI 圆角外露出"直角边"。
        // 强制 layer 透明,圆角外的像素就由窗口的透明背景接管,NSPanel 也会按真实 alpha 画阴影。
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor

        let initialFrame = settings.floatingPanelFrame ?? Self.defaultFrame()
        let panel = FloatingPanel(contentRect: initialFrame)
        panel.contentView = hosting
        // 让窗口尺寸跟随 SwiftUI 内容收缩
        hosting.frame = panel.contentView?.bounds ?? .zero
        hosting.autoresizingMask = [.width, .height]
        panel.setFrame(adjustedFrame(initialFrame), display: false)

        self.panel = panel
        self.hostingView = hosting
        registerObservers(for: panel)
    }

    private func registerObservers(for panel: NSPanel) {
        let center = NotificationCenter.default
        let move = center.addObserver(
            forName: NSWindow.didMoveNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.persistFrame()
            }
        }
        let resize = center.addObserver(
            forName: NSWindow.didEndLiveResizeNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.persistFrame()
            }
        }
        observers = [move, resize]
    }

    private func persistFrame() {
        guard let panel else { return }
        SettingsStore.shared.floatingPanelFrame = panel.frame

        // 拖动期间 didMove 会持续触发,延迟一小段时间没有新事件再吸附,
        // 用此 debounce 近似"拖动结束"语义(isMovableByWindowBackground 没有显式结束通知)
        snapTask?.cancel()
        snapTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            self?.snapToEdgeIfNeeded()
        }
    }

    private func snapToEdgeIfNeeded() {
        guard let panel else { return }
        guard let screen = panel.screen ?? NSScreen.main else { return }
        let snapped = snappedFrame(panel.frame, on: screen)
        guard snapped != panel.frame else { return }
        panel.setFrame(snapped, display: true, animate: true)
        // setFrame 会再次触发 didMove,但 snapped == snappedFrame(snapped),不会无限循环
        SettingsStore.shared.floatingPanelFrame = snapped
    }

    private func snappedFrame(_ frame: CGRect, on screen: NSScreen) -> CGRect {
        let visible = screen.visibleFrame
        let threshold = Self.snapThreshold
        var origin = frame.origin

        if abs(frame.minX - visible.minX) < threshold {
            origin.x = visible.minX
        } else if abs(visible.maxX - frame.maxX) < threshold {
            origin.x = visible.maxX - frame.width
        }

        if abs(frame.minY - visible.minY) < threshold {
            origin.y = visible.minY
        } else if abs(visible.maxY - frame.maxY) < threshold {
            origin.y = visible.maxY - frame.height
        }

        return CGRect(origin: origin, size: frame.size)
    }

    /// 若已保存的 frame 落在屏幕之外，回落到默认位置
    private func adjustedFrame(_ frame: CGRect) -> CGRect {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return frame }
        let onScreen = screens.contains { $0.visibleFrame.intersects(frame) }
        return onScreen ? frame : Self.defaultFrame()
    }

    private static func defaultFrame() -> CGRect {
        let screenFrame = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let size = defaultSize
        let origin = CGPoint(
            x: screenFrame.maxX - size.width - defaultMargin,
            y: screenFrame.maxY - size.height - defaultMargin
        )
        return CGRect(origin: origin, size: size)
    }
}

/// 悬浮窗专用的 hosting view,负责让整块 HUD 可以拖动窗口。
///
/// 只靠 `NSPanel.isMovableByWindowBackground` 不够:窗口背景拖拽要求 hitTest 命中的
/// view 的 `mouseDownCanMoveWindow` 为 true,而 `NSHostingView` 为了 SwiftUI 手势
/// 自己实现了 `mouseDown:`,默认返回 false,并且会先把事件吃掉。
/// 这里三管齐下:
/// 1. `hitTest` 一律返回自身,阻止 SwiftUI 内部子 view(如 NSVisualEffectView)抢走事件
/// 2. `mouseDownCanMoveWindow` 放行系统的背景拖拽
/// 3. `mouseDown` 里直接 `performDrag`,不依赖系统那条路径
///
/// 代价:悬浮窗内所有 SwiftUI 点击/手势都失效。当前 HUD 只有 tile、进度条和文本,
/// 没有可交互控件;后续若要加点击交互,需要改成只在局部区域放行拖拽。
private final class DraggableHostingView<Content: View>: NSHostingView<Content> {
    override var mouseDownCanMoveWindow: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}
