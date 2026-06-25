import CoreGraphics
import Foundation
import Observation
import ServiceManagement

enum QuotaIntervalChoice: String, CaseIterable, Identifiable {
    case m1
    case m2
    case m3
    case m5
    case m10

    var id: String { rawValue }

    var seconds: TimeInterval? {
        switch self {
        case .m1: return 60
        case .m2: return 2 * 60
        case .m3: return 3 * 60
        case .m5: return 5 * 60
        case .m10: return 10 * 60
        }
    }

    var displayName: String {
        switch self {
        case .m1: return "1 分钟"
        case .m2: return "2 分钟"
        case .m3: return "3 分钟"
        case .m5: return "5 分钟"
        case .m10: return "10 分钟"
        }
    }
}

enum UsageIntervalChoice: String, CaseIterable, Identifiable {
    case m1
    case m2
    case m3
    case m5
    case m10

    var id: String { rawValue }

    var seconds: TimeInterval {
        switch self {
        case .m1: return 60
        case .m2: return 2 * 60
        case .m3: return 3 * 60
        case .m5: return 5 * 60
        case .m10: return 10 * 60
        }
    }

    var displayName: String {
        switch self {
        case .m1: return "1 分钟"
        case .m2: return "2 分钟"
        case .m3: return "3 分钟"
        case .m5: return "5 分钟"
        case .m10: return "10 分钟"
        }
    }
}

enum ResetTimeDisplay: String, CaseIterable, Identifiable {
    case relative
    case absolute

    var id: String { rawValue }
}

enum MenuBarWindowChoice: String, CaseIterable, Identifiable {
    case fiveHour
    case weekly
    case both

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .fiveHour: return "5H 窗口"
        case .weekly: return "WK 窗口"
        case .both: return "两者都显示"
        }
    }
}

@Observable
@MainActor
final class SettingsStore {
    static let shared = SettingsStore()

    private let defaults: UserDefaults

    // 账号
    var showCodex: Bool { didSet { defaults.set(showCodex, forKey: Keys.showCodex) } }
    var showClaude: Bool { didSet { defaults.set(showClaude, forKey: Keys.showClaude) } }

    // 菜单栏
    var menuBarShowCodex: Bool { didSet { defaults.set(menuBarShowCodex, forKey: Keys.menuBarShowCodex) } }
    var menuBarShowClaude: Bool { didSet { defaults.set(menuBarShowClaude, forKey: Keys.menuBarShowClaude) } }
    var menuBarWindow: MenuBarWindowChoice { didSet { defaults.set(menuBarWindow.rawValue, forKey: Keys.menuBarWindow) } }

    // 悬浮窗（占位，M8 接）
    var floatingEnabled: Bool { didSet { defaults.set(floatingEnabled, forKey: Keys.floatingEnabled) } }
    var floatingShowCodex: Bool { didSet { defaults.set(floatingShowCodex, forKey: Keys.floatingShowCodex) } }
    var floatingShowClaude: Bool { didSet { defaults.set(floatingShowClaude, forKey: Keys.floatingShowClaude) } }

    // 刷新
    var quotaInterval: QuotaIntervalChoice { didSet { defaults.set(quotaInterval.rawValue, forKey: Keys.quotaInterval) } }
    var usageInterval: UsageIntervalChoice { didSet { defaults.set(usageInterval.rawValue, forKey: Keys.usageInterval) } }
    var resetTimeDisplay: ResetTimeDisplay { didSet { defaults.set(resetTimeDisplay.rawValue, forKey: Keys.resetTimeDisplay) } }

    /// 是否在 Popover 中显示 OpenAI / Anthropic 服务状态圆点
    var showServiceStatus: Bool { didSet { defaults.set(showServiceStatus, forKey: Keys.showServiceStatus) } }

    // 通用
    var appLanguage: AppLanguage { didSet { defaults.set(appLanguage.rawValue, forKey: Keys.appLanguage) } }
    var launchAtLogin: Bool { didSet { defaults.set(launchAtLogin, forKey: Keys.launchAtLogin) } }

    /// 隐私模式：Popover 中主账号邮箱、Codex 副账号名称均隐藏
    var privacyMode: Bool { didSet { defaults.set(privacyMode, forKey: Keys.privacyMode) } }

    /// 是否已经向用户解释过"接下来会出现 Keychain 授权弹窗"
    var didShowKeychainPrompt: Bool {
        didSet { defaults.set(didShowKeychainPrompt, forKey: Keys.didShowKeychainPrompt) }
    }

    /// 是否已经完成首次启动引导
    var didCompleteOnboarding: Bool {
        didSet { defaults.set(didCompleteOnboarding, forKey: Keys.didCompleteOnboarding) }
    }

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // 账号
        showCodex = defaults.object(forKey: Keys.showCodex) as? Bool ?? true
        showClaude = defaults.object(forKey: Keys.showClaude) as? Bool ?? true
        // 菜单栏
        menuBarShowCodex = defaults.object(forKey: Keys.menuBarShowCodex) as? Bool ?? true
        menuBarShowClaude = defaults.object(forKey: Keys.menuBarShowClaude) as? Bool ?? true
        let mbWindowRaw = defaults.string(forKey: Keys.menuBarWindow) ?? MenuBarWindowChoice.fiveHour.rawValue
        menuBarWindow = MenuBarWindowChoice(rawValue: mbWindowRaw) ?? .fiveHour
        // 悬浮窗
        floatingEnabled = defaults.object(forKey: Keys.floatingEnabled) as? Bool ?? false
        floatingShowCodex = defaults.object(forKey: Keys.floatingShowCodex) as? Bool ?? true
        floatingShowClaude = defaults.object(forKey: Keys.floatingShowClaude) as? Bool ?? true
        // 刷新
        let qiRaw = defaults.string(forKey: Keys.quotaInterval) ?? QuotaIntervalChoice.m2.rawValue
        quotaInterval = QuotaIntervalChoice(rawValue: qiRaw) ?? .m2
        let uiRaw = defaults.string(forKey: Keys.usageInterval) ?? UsageIntervalChoice.m2.rawValue
        usageInterval = UsageIntervalChoice(rawValue: uiRaw) ?? .m2
        let rtdRaw = defaults.string(forKey: Keys.resetTimeDisplay) ?? ResetTimeDisplay.relative.rawValue
        resetTimeDisplay = ResetTimeDisplay(rawValue: rtdRaw) ?? .relative
        showServiceStatus = defaults.object(forKey: Keys.showServiceStatus) as? Bool ?? true
        // 通用：launchAtLogin 以系统当前注册状态为准
        let langRaw = defaults.string(forKey: Keys.appLanguage) ?? AppLanguage.system.rawValue
        appLanguage = AppLanguage(rawValue: langRaw) ?? .system
        launchAtLogin = Self.isLaunchAtLoginOn(SMAppService.mainApp.status)
        privacyMode = defaults.object(forKey: Keys.privacyMode) as? Bool ?? true
        didShowKeychainPrompt = defaults.object(forKey: Keys.didShowKeychainPrompt) as? Bool ?? false
        didCompleteOnboarding = defaults.object(forKey: Keys.didCompleteOnboarding) as? Bool ?? false
    }

    /// 账号与菜单栏开关的合取，最终决定菜单栏该不该画该应用
    var effectiveMenuBarShowCodex: Bool { showCodex && menuBarShowCodex }
    var effectiveMenuBarShowClaude: Bool { showClaude && menuBarShowClaude }

    /// 悬浮窗的行可见性同样需要叠加全局「显示该应用」开关
    var effectiveFloatingShowCodex: Bool { showCodex && floatingShowCodex }
    var effectiveFloatingShowClaude: Bool { showClaude && floatingShowClaude }

    /// 把 `appLanguage` 解析为最终渲染语言。`.system` 看系统首选语言是否以 `zh` 开头。
    /// 不用 `Locale.current`:它返回的是 App 当前生效的本地化语言,工程未添加中文资源时会回退到开发语言 `en`,
    /// 导致即便系统设为中文也判定为英文。`Locale.preferredLanguages.first` 反映用户在系统设置中排首位的语言,
    /// 与 App 本地化无关,例如 `zh-Hans-CN` / `zh-Hant-TW`,前缀判断对简繁均成立。
    var resolvedLanguage: ResolvedLanguage {
        switch appLanguage {
        case .system:
            let code = Locale.preferredLanguages.first ?? "en"
            return code.hasPrefix("zh") ? .zh : .en
        case .zh: return .zh
        case .en: return .en
        }
    }

    // MARK: - Floating panel frame

    /// 悬浮窗 frame，nil 表示尚未拖动过；启动时由 controller 还原
    var floatingPanelFrame: CGRect? {
        get {
            guard
                let x = defaults.object(forKey: Keys.floatingFrameX) as? Double,
                let y = defaults.object(forKey: Keys.floatingFrameY) as? Double,
                let w = defaults.object(forKey: Keys.floatingFrameW) as? Double,
                let h = defaults.object(forKey: Keys.floatingFrameH) as? Double,
                w > 0, h > 0
            else { return nil }
            return CGRect(x: x, y: y, width: w, height: h)
        }
        set {
            if let r = newValue {
                defaults.set(Double(r.origin.x), forKey: Keys.floatingFrameX)
                defaults.set(Double(r.origin.y), forKey: Keys.floatingFrameY)
                defaults.set(Double(r.size.width), forKey: Keys.floatingFrameW)
                defaults.set(Double(r.size.height), forKey: Keys.floatingFrameH)
            } else {
                defaults.removeObject(forKey: Keys.floatingFrameX)
                defaults.removeObject(forKey: Keys.floatingFrameY)
                defaults.removeObject(forKey: Keys.floatingFrameW)
                defaults.removeObject(forKey: Keys.floatingFrameH)
            }
        }
    }

    // MARK: - Launch at login

    /// 当前系统记录的注册状态
    var launchAtLoginRegistered: Bool {
        Self.isLaunchAtLoginOn(SMAppService.mainApp.status)
    }

    /// 切换开机自启；失败时抛出原始错误
    func setLaunchAtLogin(_ enabled: Bool) throws {
        if enabled == launchAtLoginRegistered {
            launchAtLogin = enabled
            return
        }

        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
        syncLaunchAtLoginStatus()
    }

    /// 重新读取系统注册状态，避免 UserDefaults 与系统 Login Item 状态错位。
    func syncLaunchAtLoginStatus() {
        launchAtLogin = launchAtLoginRegistered
    }

    var launchAtLoginRequiresApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    private static func isLaunchAtLoginOn(_ status: SMAppService.Status) -> Bool {
        switch status {
        case .enabled, .requiresApproval:
            return true
        case .notRegistered, .notFound:
            return false
        @unknown default:
            return false
        }
    }

    private enum Keys {
        static let showCodex = "ccbar.settings.showCodex"
        static let showClaude = "ccbar.settings.showClaude"
        static let menuBarShowCodex = "ccbar.settings.menuBarShowCodex"
        static let menuBarShowClaude = "ccbar.settings.menuBarShowClaude"
        static let menuBarWindow = "ccbar.settings.menuBarWindow"
        static let floatingEnabled = "ccbar.settings.floatingEnabled"
        static let floatingShowCodex = "ccbar.settings.floatingShowCodex"
        static let floatingShowClaude = "ccbar.settings.floatingShowClaude"
        static let quotaInterval = "ccbar.settings.quotaInterval"
        static let usageInterval = "ccbar.settings.usageInterval"
        static let resetTimeDisplay = "ccbar.settings.resetTimeDisplay"
        static let showServiceStatus = "ccbar.settings.showServiceStatus"
        static let launchAtLogin = "ccbar.settings.launchAtLogin"
        static let appLanguage = "ccbar.settings.appLanguage"
        static let privacyMode = "ccbar.settings.privacyMode"
        static let didShowKeychainPrompt = "ccbar.settings.didShowKeychainPrompt"
        static let didCompleteOnboarding = "ccbar.settings.didCompleteOnboarding"
        static let floatingFrameX = "ccbar.settings.floatingFrame.x"
        static let floatingFrameY = "ccbar.settings.floatingFrame.y"
        static let floatingFrameW = "ccbar.settings.floatingFrame.w"
        static let floatingFrameH = "ccbar.settings.floatingFrame.h"
    }
}
