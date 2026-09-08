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
            let save = controls.compactMap { $0 as? NSButton }.first { $0.title == L10n.text("保存") }!
            save.performClick(nil)
            precondition(applied?.language == (language == .chinese ? .english : .chinese))
            window.close()
        }
        print("Localization UI checks passed: bilingual layouts, save without login, persistence, compact expiration")
    }
}
