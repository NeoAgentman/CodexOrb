import Foundation
import CodexOrbCore

struct AppSettings: Equatable {
    struct RefreshChoice {
        let title: String
        let seconds: TimeInterval
    }

    static let refreshChoices = [
        RefreshChoice(title: "1 分钟", seconds: 60),
        RefreshChoice(title: "5 分钟", seconds: 5 * 60),
        RefreshChoice(title: "10 分钟", seconds: 10 * 60),
        RefreshChoice(title: "15 分钟", seconds: 15 * 60),
        RefreshChoice(title: "30 分钟", seconds: 30 * 60),
        RefreshChoice(title: "1 小时", seconds: 60 * 60),
    ]

    private enum DefaultsKey {
        static let accountHome = "CodexOrb.accountHome"
        static let refreshInterval = "CodexOrb.refreshInterval"
    }

    var dailyQuotaEnabled: Bool = false
    var accountHome: String
    var provider: String { "codex" }
    var refreshInterval: TimeInterval

    static func load(from defaults: UserDefaults = .standard) -> AppSettings {
        let accountHome = defaults.string(forKey: DefaultsKey.accountHome) ?? CodexAccountStore().nativeHome.path
        let storedInterval = defaults.double(forKey: DefaultsKey.refreshInterval)
        let validInterval = Self.refreshChoices.contains(where: { $0.seconds == storedInterval })
            ? storedInterval
            : 5 * 60
        return AppSettings(dailyQuotaEnabled: DailyQuotaLaunchAgent.isEnabled, accountHome: accountHome, refreshInterval: validInterval)
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(self.accountHome, forKey: DefaultsKey.accountHome)
        defaults.removeObject(forKey: "CodexOrb.quotaProvider")
        defaults.set(self.refreshInterval, forKey: DefaultsKey.refreshInterval)
    }

}
