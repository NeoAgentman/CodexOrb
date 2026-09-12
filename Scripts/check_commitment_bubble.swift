import AppKit
import CodexOrbCore

@main
struct CommitmentBubbleChecks {
    @MainActor static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        Task { @MainActor in
            do {
                try await runChecks()
                print("Commitment bubble checks passed: transitions, deduplication, timeout, focus, compact bilingual layout and opening quota details")
                exit(0)
            } catch { fatalError("Commitment bubble checks failed: \(error)") }
        }
        NSApp.run()
    }

    @MainActor static func runChecks() async throws {
        let suite = "CodexOrb.CommitmentBubbleChecks.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            defaults.removePersistentDomain(forName: suite)
            UserDefaults.standard.removeVolatileDomain(forName: UserDefaults.argumentDomain)
        }
        func forecast(_ percent: Int?) -> CodexResetForecast {
            .init(probability24h: 45, probability48h: 70, confidence: nil,
                  updatedAt: Date(), commitmentPercent: percent)
        }
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let controller = OrbPanelController(defaults: defaults, commitmentNoticeDuration: .milliseconds(400))
        controller.show()
        defer { controller.close() }
        let orb = NSApp.windows.compactMap { $0.contentView as? OrbView }.first!
        let anchor = orb.window!
        let bubble = NSApp.windows.compactMap { $0 as? CommitmentBubble }.first!

        controller.updateForecast(nil)
        controller.updateForecast(forecast(83))
        precondition(!bubble.isVisible, "First successful result is a baseline, not a new commitment")
        controller.updateForecast(nil)
        controller.updateForecast(forecast(85))
        precondition(!bubble.isVisible, "A missing result cannot create a false transition")
        controller.updateForecast(forecast(nil))
        controller.updateForecast(nil)
        controller.updateForecast(forecast(83))
        precondition(bubble.isVisible, "Absent to present must show the bubble even without an X URL")
        precondition(!bubble.canBecomeKey && !bubble.canBecomeMain && !bubble.ignoresMouseEvents,
                     "The notice must accept clicks without taking focus when shown")
        precondition(NSWorkspace.shared.frontmostApplication?.processIdentifier == frontmost,
                     "Showing the notice activated a different application")
        try await Task.sleep(for: .milliseconds(250))
        controller.updateForecast(forecast(90))
        try await Task.sleep(for: .milliseconds(250))
        precondition(!bubble.isVisible, "Repeated presence must not restart the dismissal timer")
        controller.updateForecast(forecast(83))
        precondition(!bubble.isVisible, "Repeated presence must not re-show a dismissed notice")

        for language in AppLanguage.allCases {
            UserDefaults.standard.setVolatileDomain([AppLanguage.defaultsKey: language.rawValue],
                                                   forName: UserDefaults.argumentDomain)
            controller.updateForecast(forecast(nil))
            controller.updateForecast(forecast(83))
            precondition(bubble.isVisible, "A later absent-to-present transition must notify again")
            let content = bubble.contentView as! CommitmentBubbleView
            let buttons = content.subviews.compactMap { $0 as? NSButton }
            precondition(buttons.count == 1 && content.subviews.count == 1,
                         "The compact notice must contain only its clickable title")
            let button = buttons[0]
            precondition(button.title == L10n.text("新的Tibo重置"))
            precondition(button.acceptsFirstMouse(for: nil), "Click must work while the app is inactive")
            precondition(content.bounds.contains(button.frame))
            precondition(button.intrinsicContentSize.width <= button.frame.width + 1,
                         "Clipped notice title: \(button.title)")
            precondition(content.frame.width <= 140 && content.frame.height == 38,
                         "The notice should remain a small single-line bubble")

            let screen = anchor.screen!.visibleFrame
            let original = anchor.frame
            for x in [screen.minX, screen.maxX - original.width] {
                for y in [screen.minY, screen.maxY - original.height] {
                    anchor.setFrameOrigin(CGPoint(x: x, y: y))
                    bubble.reposition(beside: anchor)
                    precondition(screen.contains(bubble.frame), "Bubble extends outside the visible screen")
                    precondition(!bubble.frame.intersects(anchor.frame), "Bubble covers the capsule")
                }
            }
            anchor.setFrame(original, display: true)
            controller.updateDefaultExpansion(true, animated: false)
            precondition(bubble.isVisible && !bubble.frame.intersects(anchor.frame))

            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                bubble.appearance = NSAppearance(named: appearance)
                bubble.display()
                content.layoutSubtreeIfNeeded()
                let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds)!
                content.cacheDisplay(in: content.bounds, to: bitmap)
                let url = URL(fileURLWithPath: NSTemporaryDirectory())
                    .appendingPathComponent("orb-commitment-\(language.rawValue)-\(appearance.rawValue).png")
                try bitmap.representation(using: .png, properties: [:])!.write(to: url)
            }
            controller.updateForecast(forecast(0))
            precondition(!bubble.isVisible, "A removed commitment must hide a stale notice")
        }
        controller.updateForecast(forecast(83))
        precondition(bubble.isVisible)
        let button = bubble.contentView!.subviews.compactMap { $0 as? NSButton }.first!
        button.performClick(nil)
        try await Task.sleep(for: .milliseconds(100))
        precondition(!bubble.isVisible, "Clicking the notice must dismiss it")
        func quotaCardIsVisible() -> Bool {
            NSApp.windows.contains {
                $0.isVisible && $0.contentViewController?.view is QuotaDetailsView
            }
        }
        precondition(quotaCardIsVisible(), "Clicking the notice must open the quota details card")
        controller.updateForecast(forecast(nil))
        controller.updateForecast(forecast(83))
        button.performClick(nil)
        precondition(quotaCardIsVisible(), "Clicking a new notice must keep an existing quota card open")
        controller.updateForecast(forecast(nil))
        controller.updateForecast(forecast(83))
        controller.close()
        precondition(!bubble.isVisible, "Closing the capsule must cancel and dismiss its notice")
        try await Task.sleep(for: .milliseconds(450))
        precondition(!bubble.isVisible)
    }
}
