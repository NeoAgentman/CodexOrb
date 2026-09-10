import AppKit
import CodexOrbCore

@main
struct AppearanceChecks {
    @MainActor static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        Task { @MainActor in
            do {
                try await runChecks()
                exit(0)
            } catch {
                fatalError("Appearance checks failed: \(error)")
            }
        }
        NSApp.run()
    }

    @MainActor static func runChecks() async throws {
        let suite = "CodexOrb.AppearanceChecks.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        // Keep fixture language and settings isolated from the installed app.
        UserDefaults.standard.setVolatileDomain(
            [AppLanguage.defaultsKey: AppLanguage.chinese.rawValue], forName: UserDefaults.argumentDomain)
        precondition(AppSettings.load(from: defaults).appearance == .system)
        defaults.set("future-appearance", forKey: "CodexOrb.appearance")
        precondition(AppSettings.load(from: defaults).appearance == .system)
        for mode in AppAppearance.allCases {
            AppSettings(appearance: mode, refreshInterval: 300).save(to: defaults)
            precondition(AppSettings.load(from: defaults).appearance == mode)
        }
        AppAppearance.system.apply()
        let systemName = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])!
        let credits = CodexResetCredits(availableCount: 2, credits: [
            .init(id: "fixture-a", status: "available", resetType: "codexRateLimits", expiresAt: Date().addingTimeInterval(3600)),
            .init(id: "fixture-b", status: "available", resetType: "codexRateLimits", expiresAt: Date().addingTimeInterval(864000)),
        ])
        let usage = CodexUsage(
            windows: [
                .init(kind: .fiveHour, usedPercent: 20, resetsAt: Date().addingTimeInterval(3600), resetDescription: nil),
                .init(kind: .weekly, usedPercent: 40, resetsAt: Date().addingTimeInterval(86400), resetDescription: nil),
            ],
            todayTokens: .init(date: "2026-09-10", totalTokens: 300000, cacheReadTokens: 600000, inputTokens: 100000,
                              toolUsages: [.init(tool: "codex", totalTokens: 200000, cacheReadTokens: 300000),
                                           .init(tool: "hermes", totalTokens: 100000, cacheReadTokens: 300000)],
                              modelUsages: [.init(model: "gpt-5.6-sol", totalTokens: 300000, cacheReadTokens: 600000)]),
            resetCredits: credits,
            updatedAt: Date())
        let controller = OrbPanelController(defaults: defaults)
        controller.updateDefaultExpansion(true, animated: false)
        controller.updateAccount(nil)
        controller.update(.available(usage))
        controller.show()
        defer { controller.close() }
        let panel = NSApp.windows.first { $0.contentView is OrbView }!
        let orb = panel.contentView as! OrbView
        let settings = SettingsWindowController(settings: .init(refreshInterval: 300), onApply: { _ in })
        settings.window!.orderFront(nil)
        defer { settings.close() }
        let output = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("codexorb-appearance-checks")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        // Change the application appearance with existing windows and popovers still open.
        for kind in ["quota", "tokens", "resets"] {
            switch kind {
            case "quota": controller.orbViewDidRequestQuotaDetails(orb)
            case "tokens": controller.orbViewDidRequestTokenDetails(orb)
            default: controller.orbViewDidRequestResetCards(orb)
            }
            // Let the previous transient popover finish its close animation.
            try await Task.sleep(for: .milliseconds(350))
            for mode in [AppAppearance.dark, .light, .system] {
                mode.apply()
                try await Task.sleep(for: .milliseconds(80))
                let expected: NSAppearance.Name = mode == .system ? systemName : (mode == .dark ? .darkAqua : .aqua)
                if mode == .system { precondition(NSApp.appearance == nil) }
                for window in NSApp.windows where window.isVisible {
                    precondition(window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == expected,
                                 "Window failed to inherit \(mode): \(window.className), requested=\(String(describing: window.appearance)), effective=\(window.effectiveAppearance.name), app=\(NSApp.effectiveAppearance.name)")
                    if let content = window.contentView {
                        for view in descendants(content) {
                            precondition(view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == expected,
                                         "View failed to inherit \(mode): \(view.className)")
                        }
                    }
                }
                let popover = NSApp.windows.compactMap { $0.contentViewController?.view }.first {
                    $0.window?.isVisible == true && ($0 is QuotaDetailsView || $0 is TokenDetailsView || $0 is ResetCardsScrollView)
                }!
                try snapshot(popover, to: output.appendingPathComponent("\(kind)-\(mode.rawValue).png"))
                if kind == "quota" {
                    try snapshot(settings.window!.contentView!, to: output.appendingPathComponent("settings-\(mode.rawValue).png"))
                    try snapshot(orb, to: output.appendingPathComponent("capsule-\(mode.rawValue).png"))
                }
            }
        }
        // A newly created window must inherit the saved selection too.
        AppAppearance.dark.apply()
        let newWindow = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        precondition(newWindow.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
        AppAppearance.system.apply()
        precondition(newWindow.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == systemName)
        print("Appearance checks passed: persistence, fallback, existing windows/popovers, new windows, return to system; snapshots: \(output.path)")
    }

    @MainActor static func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    @MainActor static func snapshot(_ view: NSView, to url: URL) throws {
        view.layoutSubtreeIfNeeded()
        let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: bitmap)
        // Composite transparent view snapshots over their native background for inspection.
        let image = NSImage(size: view.bounds.size)
        image.lockFocus()
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill()
            NSBezierPath(rect: NSRect(origin: .zero, size: view.bounds.size)).fill()
            bitmap.draw(in: NSRect(origin: .zero, size: view.bounds.size))
        }
        image.unlockFocus()
        let flattened = NSBitmapImageRep(data: image.tiffRepresentation!)!
        try flattened.representation(using: .png, properties: [:])!.write(to: url)
    }
}
