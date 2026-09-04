import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var openStatisticsWindow: (() -> Void)?
    private var shouldOpenStatisticsWhenReady = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // 冷启动（含开机自启、Dock/应用程序/Launchpad/Raycast 手动启动）一律静默，
        // 只驻留菜单栏；主窗口只在用户点 Dock 图标触发 reopen 时才打开。
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
}
