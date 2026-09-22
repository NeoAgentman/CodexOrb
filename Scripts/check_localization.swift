// Compile alongside the AppKit view sources and CodexOrbCore objects.
// Uses temporary defaults and a no-op apply callback; does not change app settings.
import AppKit
import CodexOrbCore

@main
struct Preview {
    @MainActor static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let suite = "orb-preview-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        precondition(AppSettings.load(from: defaults).automaticReset == AutomaticResetPolicy(), "automatic consumption defaults off and current-account only")
        for hours in [1, 12] {
            let policy = AutomaticResetPolicy(enabled: true, hoursBeforeExpiration: hours, allAccounts: true)
            AppSettings(refreshInterval: 300, automaticReset: policy).save(to: defaults)
            precondition(AppSettings.load(from: defaults).automaticReset == policy, "automatic settings persist")
        }
        defaults.set(99, forKey: "CodexOrb.automaticReset.hours")
        precondition(AppSettings.load(from: defaults).automaticReset.hoursBeforeExpiration == 6, "invalid threshold falls back to six hours")
        for language in AppLanguage.allCases {
            let saved = AppSettings(language: language, accountHome: "/tmp/unavailable-test-account", refreshInterval: 300)
            saved.save(to: defaults)
            precondition(AppSettings.load(from: defaults).language == language)
        }
        let legacyNative = AppSettings(language: .chinese, accountHome: "/tmp/native-codex-home", refreshInterval: 300)
        legacyNative.save(to: defaults)
        precondition(AppSettings.load(from: defaults).accountHome == nil,
                     "Native or unavailable account must not be selected")
        for language in AppLanguage.allCases {
            UserDefaults.standard.setVolatileDomain([AppLanguage.defaultsKey: language.rawValue], forName: UserDefaults.argumentDomain)
            var settings = AppSettings.load()
            settings.automaticReset = AutomaticResetPolicy()
            settings.accountHome = "/tmp/unavailable-test-account"
            var applied: AppSettings?
            let controller = SettingsWindowController(settings: settings, onApply: { applied = $0 })
            guard let window = controller.window, let view = window.contentView else { fatalError() }
            window.orderFront(nil)
            view.layoutSubtreeIfNeeded()
            func check(_ child: NSView) {
                if let field = child as? NSTextField, !field.isHidden, !field.stringValue.isEmpty {
                    let rect = field.convert(field.bounds, to: view)
                    precondition(rect.minY >= 0 && rect.maxY <= view.bounds.height + 1, "Outside window: \(field.stringValue) \(rect)")
                }
                child.subviews.forEach(check)
            }
            check(view)
            func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
            let autoControls = descendants(view)
            let automatic = autoControls.compactMap { $0 as? NSButton }.first { $0.title == L10n.text("自动使用即将到期的重置卡") }!
            let allAccounts = autoControls.compactMap { $0 as? NSButton }.first { $0.title == L10n.text("应用到所有账号") }!
            let hours = autoControls.compactMap { $0 as? NSPopUpButton }.first { $0.numberOfItems == 12 }!
            precondition(automatic.state == .off && allAccounts.state == .off && hours.indexOfSelectedItem == 5)
            precondition(!hours.isEnabled && !allAccounts.isEnabled, "dependent options disabled until enabled")
            automatic.performClick(nil)
            precondition(hours.isEnabled && allAccounts.isEnabled)
            allAccounts.performClick(nil)
            hours.selectItem(at: 11)
            automatic.performClick(nil)
            precondition(!hours.isEnabled && !allAccounts.isEnabled && allAccounts.state == .on, "disabling preserves configured scope")
            automatic.performClick(nil)
            let startup = descendants(view).compactMap { $0 as? NSBox }.first!
            let startupSwitch = descendants(startup).compactMap { $0 as? NSSwitch }.first!
            let switchRect = startupSwitch.convert(startupSwitch.bounds, to: startup)
            precondition(switchRect.minY <= 20, "Startup card has excess bottom space: \(switchRect.minY) pt")
            let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "/tmp/orb-settings-\(language.rawValue).png"))
            let now = Date(timeIntervalSince1970: 1_000_000)
            let expiry = now.addingTimeInterval(3600 * 2)
            precondition(ResetCardsView.expirationText(expiry, now: now, compact: true) == (language == .english ? "2h" : "2时"))
            precondition(ResetCardsView.expirationText(nil, now: now, compact: true) == (language == .english ? "—" : "未知"))
            let controls = descendants(view)
            let popup = controls.compactMap { $0 as? NSPopUpButton }.first { $0.itemTitles == ["中文", "English"] }!
            popup.selectItem(at: language == .chinese ? 1 : 0)
            let appearance = controls.compactMap { $0 as? NSPopUpButton }
                .first { $0.itemTitles == AppAppearance.allCases.map(\.title) }!
            precondition(appearance.indexOfSelectedItem == AppAppearance.allCases.firstIndex(of: settings.appearance))
            appearance.selectItem(at: 2)
            let save = controls.compactMap { $0 as? NSButton }.first { $0.title == L10n.text("保存") }!
            save.performClick(nil)
            precondition(applied?.language == (language == .chinese ? .english : .chinese))
            precondition(applied?.appearance == .dark)
            precondition(applied?.automaticReset == AutomaticResetPolicy(enabled: true, hoursBeforeExpiration: 12, allAccounts: true), "save captures all automatic settings")
            window.close()
        }
        print("Localization UI checks passed: bilingual layouts, save without login, persistence, compact expiration")
    }
}
