import SwiftUI

enum MainTab: Hashable {
    case stats
    case settings
}

struct MainWindowRootView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var bindable = appState
        TabView(selection: $bindable.mainTab) {
            StatsView()
                .tabItem { Label(tr("Statistics", "用量统计"), systemImage: "chart.bar") }
                .tag(MainTab.stats)

            SettingsRootView()
                .tabItem { Label(tr("Settings", "设置"), systemImage: "gearshape") }
                .tag(MainTab.settings)
        }
        .frame(minWidth: 1040, minHeight: 520)
        .toolbar {
            // 用量重新计算(冷启动自动重扫、设置页手动重算、周期性扫描)进行中时,
            // 在窗口顶部给一个全局提示,避免用户切到统计页看到数据短暂清空却不知道原因。
            ToolbarItem(placement: .navigation) {
                if appState.usageService.isScanning {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text(tr("Recalculating usage…", "正在重新计算用量…"))
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}
