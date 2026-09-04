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
}

enum ResetTimeDisplay: String, CaseIterable, Identifiable {
    case relative
    case absolute

    var id: String { rawValue }
}

/// Which quota lane the menu bar, HUD and popover headline show. Raw values
/// keep the pre-multi-provider spelling so stored preferences survive.
enum MenuBarWindowChoice: String, CaseIterable, Identifiable {
    case primary = "fiveHour"
    case secondary = "weekly"
    case both

    var id: String { rawValue }

    var toggledForMenuBar: MenuBarWindowChoice {
        switch self {
        case .primary: return .secondary
        case .secondary: return .primary
        case .both: return .secondary
        }
    }
}

enum MenuBarMode: String, CaseIterable, Identifiable {
    /// One segment per enabled provider.
    case all
    /// Only the provider with the least remaining quota.
    case lowestOnly

    var id: String { rawValue }
}

/// How each menu bar segment renders its quota: a percent string or a small vertical meter.
enum MenuBarStyle: String, CaseIterable, Identifiable {
    case percent
    case meter

    var id: String { rawValue }
}

@Observable
@MainActor
final class SettingsStore {
    static let shared = SettingsStore()

    private let defaults: UserDefaults

    // Accounts: which providers are monitored at all.
    var enabledProviders: Set<Provider> { didSet { save(enabledProviders, forKey: Keys.enabledProviders) } }

    // Menu bar.
    var menuBarProviders: Set<Provider> { didSet { save(menuBarProviders, forKey: Keys.menuBarProviders) } }
    var menuBarWindow: MenuBarWindowChoice { didSet { defaults.set(menuBarWindow.rawValue, forKey: Keys.menuBarWindow) } }
    var menuBarMode: MenuBarMode { didSet { defaults.set(menuBarMode.rawValue, forKey: Keys.menuBarMode) } }
    var menuBarStyle: MenuBarStyle { didSet { defaults.set(menuBarStyle.rawValue, forKey: Keys.menuBarStyle) } }

    // Floating HUD.
    var floatingEnabled: Bool { didSet { defaults.set(floatingEnabled, forKey: Keys.floatingEnabled) } }
    var floatingProviders: Set<Provider> { didSet { save(floatingProviders, forKey: Keys.floatingProviders) } }

    // Refresh.
    var quotaInterval: QuotaIntervalChoice { didSet { defaults.set(quotaInterval.rawValue, forKey: Keys.quotaInterval) } }
    var usageInterval: UsageIntervalChoice { didSet { defaults.set(usageInterval.rawValue, forKey: Keys.usageInterval) } }
    var resetTimeDisplay: ResetTimeDisplay { didSet { defaults.set(resetTimeDisplay.rawValue, forKey: Keys.resetTimeDisplay) } }
    var showServiceStatus: Bool { didSet { defaults.set(showServiceStatus, forKey: Keys.showServiceStatus) } }
    /// Local notifications at 20% left, on exhaustion, and when a window resets.
    var quotaNotifications: Bool { didSet { defaults.set(quotaNotifications, forKey: Keys.quotaNotifications) } }

    // General.
    var appLanguage: AppLanguage { didSet { defaults.set(appLanguage.rawValue, forKey: Keys.appLanguage) } }
    var launchAtLogin: Bool { didSet { defaults.set(launchAtLogin, forKey: Keys.launchAtLogin) } }
    var privacyMode: Bool { didSet { defaults.set(privacyMode, forKey: Keys.privacyMode) } }
    var didShowKeychainPrompt: Bool { didSet { defaults.set(didShowKeychainPrompt, forKey: Keys.didShowKeychainPrompt) } }
    var didCompleteOnboarding: Bool { didSet { defaults.set(didCompleteOnboarding, forKey: Keys.didCompleteOnboarding) } }

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        enabledProviders = Self.loadProviders(
            defaults, key: Keys.enabledProviders,
            legacy: (codex: Keys.legacyShowCodex, claude: Keys.legacyShowClaude)
        )
        menuBarProviders = Self.loadProviders(
            defaults, key: Keys.menuBarProviders,
            legacy: (codex: Keys.legacyMenuBarShowCodex, claude: Keys.legacyMenuBarShowClaude)
        )
        floatingProviders = Self.loadProviders(
            defaults, key: Keys.floatingProviders,
            legacy: (codex: Keys.legacyFloatingShowCodex, claude: Keys.legacyFloatingShowClaude)
        )

        let mbWindowRaw = defaults.string(forKey: Keys.menuBarWindow) ?? MenuBarWindowChoice.primary.rawValue
        menuBarWindow = MenuBarWindowChoice(rawValue: mbWindowRaw) ?? .primary
        let modeRaw = defaults.string(forKey: Keys.menuBarMode) ?? MenuBarMode.all.rawValue
        menuBarMode = MenuBarMode(rawValue: modeRaw) ?? .all
        let styleRaw = defaults.string(forKey: Keys.menuBarStyle) ?? MenuBarStyle.percent.rawValue
        menuBarStyle = MenuBarStyle(rawValue: styleRaw) ?? .percent
        floatingEnabled = defaults.object(forKey: Keys.floatingEnabled) as? Bool ?? false

        let qiRaw = defaults.string(forKey: Keys.quotaInterval) ?? QuotaIntervalChoice.m2.rawValue
        quotaInterval = QuotaIntervalChoice(rawValue: qiRaw) ?? .m2
        let uiRaw = defaults.string(forKey: Keys.usageInterval) ?? UsageIntervalChoice.m2.rawValue
        usageInterval = UsageIntervalChoice(rawValue: uiRaw) ?? .m2
        let rtdRaw = defaults.string(forKey: Keys.resetTimeDisplay) ?? ResetTimeDisplay.relative.rawValue
        resetTimeDisplay = ResetTimeDisplay(rawValue: rtdRaw) ?? .relative
        showServiceStatus = defaults.object(forKey: Keys.showServiceStatus) as? Bool ?? true
        quotaNotifications = defaults.object(forKey: Keys.quotaNotifications) as? Bool ?? false

        let langRaw = defaults.string(forKey: Keys.appLanguage) ?? AppLanguage.system.rawValue
        appLanguage = AppLanguage(rawValue: langRaw) ?? .system
        launchAtLogin = defaults.object(forKey: Keys.launchAtLogin) as? Bool ?? false
        privacyMode = defaults.object(forKey: Keys.privacyMode) as? Bool ?? true
        didShowKeychainPrompt = defaults.object(forKey: Keys.didShowKeychainPrompt) as? Bool ?? false
        didCompleteOnboarding = defaults.object(forKey: Keys.didCompleteOnboarding) as? Bool ?? false
    }

    // MARK: - Provider sets

    func isEnabled(_ provider: Provider) -> Bool {
        enabledProviders.contains(provider)
    }

    func setEnabled(_ provider: Provider, _ enabled: Bool) {
        if enabled { enabledProviders.insert(provider) } else { enabledProviders.remove(provider) }
    }

    func setMenuBar(_ provider: Provider, _ shown: Bool) {
        if shown { menuBarProviders.insert(provider) } else { menuBarProviders.remove(provider) }
    }

    func setFloating(_ provider: Provider, _ shown: Bool) {
        if shown { floatingProviders.insert(provider) } else { floatingProviders.remove(provider) }
    }

    /// Providers drawn in the menu bar: enabled globally and enabled for the bar.
    var effectiveMenuBarProviders: [Provider] {
        Provider.allCases.filter { enabledProviders.contains($0) && menuBarProviders.contains($0) }
    }

    var effectiveFloatingProviders: [Provider] {
        Provider.allCases.filter { enabledProviders.contains($0) && floatingProviders.contains($0) }
    }

    /// New installs and pre-provider installs: every provider on, with the two
    /// legacy booleans honoured when they were explicitly set.
    private static func loadProviders(
        _ defaults: UserDefaults,
        key: String,
        legacy: (codex: String, claude: String)
    ) -> Set<Provider> {
        if let stored = defaults.array(forKey: key) as? [String] {
            return Set(stored.compactMap(Provider.init(rawValue:)))
        }
        var set = Set(Provider.allCases)
        if let codex = defaults.object(forKey: legacy.codex) as? Bool, !codex { set.remove(.codex) }
        if let claude = defaults.object(forKey: legacy.claude) as? Bool, !claude { set.remove(.claude) }
        return set
    }

    private func save(_ providers: Set<Provider>, forKey key: String) {
        defaults.set(Provider.allCases.filter(providers.contains).map(\.rawValue), forKey: key)
    }

    var resolvedLanguage: ResolvedLanguage {
        switch appLanguage {
        case .system:
            // `Locale.current` falls back to the development language when the
            // bundle has no zh lproj; preferredLanguages reflects the system setting.
            let code = Locale.preferredLanguages.first ?? "en"
            return code.hasPrefix("zh") ? .zh : .en
        case .zh: return .zh
        case .en: return .en
        }
    }

    // MARK: - Floating panel frame

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

    var launchAtLoginRegistered: Bool {
        SMAppService.mainApp.status == .enabled
    }

    func setLaunchAtLogin(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
        launchAtLogin = enabled
    }

    private enum Keys {
        static let enabledProviders = "ccbar.settings.enabledProviders"
        static let menuBarProviders = "ccbar.settings.menuBarProviders"
        static let floatingProviders = "ccbar.settings.floatingProviders"
        static let menuBarMode = "ccbar.settings.menuBarMode"
        static let menuBarStyle = "ccbar.settings.menuBarStyle"
        static let quotaNotifications = "ccbar.settings.quotaNotifications"
        static let legacyShowCodex = "ccbar.settings.showCodex"
        static let legacyShowClaude = "ccbar.settings.showClaude"
        static let legacyMenuBarShowCodex = "ccbar.settings.menuBarShowCodex"
        static let legacyMenuBarShowClaude = "ccbar.settings.menuBarShowClaude"
        static let legacyFloatingShowCodex = "ccbar.settings.floatingShowCodex"
        static let legacyFloatingShowClaude = "ccbar.settings.floatingShowClaude"
        static let menuBarWindow = "ccbar.settings.menuBarWindow"
        static let floatingEnabled = "ccbar.settings.floatingEnabled"
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
