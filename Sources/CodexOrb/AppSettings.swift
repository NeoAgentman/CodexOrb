import AppKit
import CodexOrbCore

enum AppAppearance: String, CaseIterable {
    case system
    case light
    case dark

    var title: String {
        switch self {
        case .system: L10n.text("跟随系统")
        case .light: L10n.text("浅色")
        case .dark: L10n.text("深色")
        }
    }

    @MainActor func apply() {
        switch self {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

struct AppSettings: Equatable {
    struct RefreshChoice {
        let title: String
        let seconds: TimeInterval
    }

    static var refreshChoices: [RefreshChoice] { [
        RefreshChoice(title: L10n.text("1 分钟"), seconds: 60),
        RefreshChoice(title: L10n.text("5 分钟"), seconds: 5 * 60),
        RefreshChoice(title: L10n.text("10 分钟"), seconds: 10 * 60),
        RefreshChoice(title: L10n.text("15 分钟"), seconds: 15 * 60),
        RefreshChoice(title: L10n.text("30 分钟"), seconds: 30 * 60),
        RefreshChoice(title: L10n.text("1 小时"), seconds: 60 * 60),
    ] }

    private enum DefaultsKey {
        static let accountHome = "CodexOrb.accountHome"
        static let capsuleExpandedByDefault = "CodexOrb.capsuleExpandedByDefault"
        static let refreshInterval = "CodexOrb.refreshInterval"
        static let appearance = "CodexOrb.appearance"
    }

    var language: AppLanguage = .chinese
    var appearance: AppAppearance = .system
    var accountHome: String?
    var capsuleExpandedByDefault: Bool = false
    var provider: String { "codex" }
    var refreshInterval: TimeInterval

    static func load(from defaults: UserDefaults = .standard) -> AppSettings {
        let store = CodexAccountStore()
        let accountHome = defaults.string(forKey: DefaultsKey.accountHome)
            .flatMap { store.managedAccount(at: URL(fileURLWithPath: $0))?.home }
        let storedInterval = defaults.double(forKey: DefaultsKey.refreshInterval)
        let validInterval = Self.refreshChoices.contains(where: { $0.seconds == storedInterval })
            ? storedInterval
            : 5 * 60
        return AppSettings(
            language: AppLanguage.load(from: defaults),
            appearance: defaults.string(forKey: DefaultsKey.appearance).flatMap(AppAppearance.init(rawValue:)) ?? .system,
            accountHome: accountHome,
            capsuleExpandedByDefault: defaults.bool(forKey: DefaultsKey.capsuleExpandedByDefault),
            refreshInterval: validInterval)
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(self.language.rawValue, forKey: AppLanguage.defaultsKey)
        defaults.set(self.appearance.rawValue, forKey: DefaultsKey.appearance)
        if let accountHome = self.accountHome {
            defaults.set(accountHome, forKey: DefaultsKey.accountHome)
        } else {
            defaults.removeObject(forKey: DefaultsKey.accountHome)
        }
        defaults.set(self.capsuleExpandedByDefault, forKey: DefaultsKey.capsuleExpandedByDefault)
        defaults.removeObject(forKey: "CodexOrb.quotaProvider")
        defaults.set(self.refreshInterval, forKey: DefaultsKey.refreshInterval)
    }

}
