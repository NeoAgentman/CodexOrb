import AppKit
import CodexOrbCore

@main
struct TokenDetailsPopoverChecks {
    @MainActor
    static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let suite = "CodexOrb.TokenDetailsPopoverChecks.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let controller = OrbPanelController(defaults: defaults)
        controller.updateDefaultExpansion(true, animated: false)
        controller.show()
        defer { controller.close() }
        guard let panel = NSApp.windows.first(where: { $0.contentView is OrbView }),
              let view = panel.contentView as? OrbView else {
            fatalError("Missing capsule")
        }

        let daily = OpenTokenDailyUsage(
            date: "2026-09-08",
            totalTokens: 293_700,
            cacheReadTokens: 7_651_300,
            inputTokens: 50_000,
            toolUsages: [
                OpenTokenToolUsage(tool: "codex", totalTokens: 1_000, cacheReadTokens: 2_000),
                OpenTokenToolUsage(tool: "hermes", totalTokens: 2_000, cacheReadTokens: 3_000),
            ],
            modelUsages: [
                OpenTokenModelUsage(model: "gpt-5.6-sol", totalTokens: 1_500, cacheReadTokens: 2_500),
                OpenTokenModelUsage(model: "gpt-5.6-luna", totalTokens: 1_500, cacheReadTokens: 2_500),
            ])
        controller.update(.available(CodexUsage(
            session: nil,
            weekly: nil,
            todayTokens: daily,
            updatedAt: Date())))

        func event(_ type: NSEvent.EventType) -> NSEvent {
            let location = view.convert(CGPoint(x: 130, y: 28), to: nil)
            return NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: 0,
                                      windowNumber: panel.windowNumber, context: nil, eventNumber: 0,
                                      clickCount: 1, pressure: 1)!
        }
        view.mouseDown(with: event(.leftMouseDown))
        view.mouseUp(with: event(.leftMouseUp))

        precondition(abs(view.tokenDetailsRect.maxY - view.resetCardsRect.maxY) < 0.001,
                     "Token and reset popovers should share the capsule's outer anchor edge")

        guard let content = NSApp.windows.compactMap({ $0.contentViewController?.view as? TokenDetailsView }).first,
              content.window?.isVisible == true else {
            fatalError("Token details popover did not appear")
        }
        let labels = self.descendants(of: content).compactMap { ($0 as? NSTextField)?.stringValue }
        for expected in ["按工具", "按模型", "codex", "hermes", "sol", "luna"] {
            precondition(labels.contains(expected), "Token details is missing: \(expected)")
        }
        let percentageLabels = labels.filter { $0.contains("%") }
        precondition(percentageLabels.count == 1, "Only the cache hit rate percentage should be shown")
        let expectedCacheAmount = AppLanguage.load() == .chinese ? "765.1万" : "7.7M"
        precondition(percentageLabels.contains { $0.contains(expectedCacheAmount) && $0.contains("99.4%") },
                     "Cache read amount and hit rate should be shown together")
        let expectedTotalAmount = AppLanguage.load() == .chinese ? "794.5万" : "7.9M"
        precondition(labels.contains(expectedTotalAmount),
                     "Token total should include a compact unit")
        print("Token details popover check passed: tool and model sections rendered")
    }

    @MainActor
    private static func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { self.descendants(of: $0) }
    }
}
