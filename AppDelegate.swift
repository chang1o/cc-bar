import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var openStatisticsWindow: (() -> Void)?
    private var shouldOpenStatisticsWhenReady = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // SMAppService 的开机自启继续静默；用户从 Dock、应用程序、Launchpad
        // 或 Raycast 冷启动时，待 SwiftUI 的 openWindow 环境就绪后打开统计页。
        guard !Self.wasLaunchedAsLoginItem else { return }
        requestOpenStatisticsWindow()
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        requestOpenStatisticsWindow()
        return false
    }

    func installOpenStatisticsHandler(_ handler: @escaping () -> Void) {
        openStatisticsWindow = handler
        guard shouldOpenStatisticsWhenReady else { return }
        shouldOpenStatisticsWhenReady = false
        handler()
    }

    private func requestOpenStatisticsWindow() {
        guard let openStatisticsWindow else {
            shouldOpenStatisticsWhenReady = true
            return
        }
        openStatisticsWindow()
    }

    private static var wasLaunchedAsLoginItem: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else { return false }
        return event.eventID == kAEOpenApplication
            && event.paramDescriptor(forKeyword: keyAELaunchedAsLogInItem) != nil
    }
}
