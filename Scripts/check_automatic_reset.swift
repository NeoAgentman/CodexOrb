import AppKit
import CodexOrbCore

/// Exercises a real window with fixture identities only. No redemption service is called.
@main
struct AutomaticResetConfirmationChecks {
    @MainActor static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        Task { @MainActor in
            await run()
            exit(0)
        }
        NSApp.run()
    }

    @MainActor static func run() async {
        let confirmation = AutomaticResetConfirmation()
        let items = [
            AutomaticResetConfirmation.Item(account: "first@example.test · pro", expiresAt: Date().addingTimeInterval(1800)),
            .init(account: "second@example.test · plus", expiresAt: Date().addingTimeInterval(3600)),
        ]
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        for language in AppLanguage.allCases {
            UserDefaults.standard.setVolatileDomain([AppLanguage.defaultsKey: language.rawValue], forName: UserDefaults.argumentDomain)
            let task = Task { await confirmation.confirm(items: items) }
            try? await Task.sleep(for: .milliseconds(50))
            let view = confirmation.window!.contentView!
            let children = descendants(view)
            let texts = children.compactMap { ($0 as? NSTextField)?.stringValue }
            precondition(items.allSatisfy { texts.contains($0.account) }, "Every planned account is visible in the list")
            let expires = texts.filter { $0.contains(language == .english ? "Expires:" : "到期时间：") }
            precondition(expires.count == 2, "Each planned card has its own expiration")
            precondition(texts.contains { $0.contains("30") }, "Countdown starts at 30 seconds")
            let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "/tmp/orb-automatic-reset-\(language.rawValue).png"))
            let cancel = children.compactMap { $0 as? NSButton }.first { $0.title == L10n.text("取消不使用") }!
            cancel.performClick(nil)
            let cancelled = await task.value
            precondition(cancelled == .cancel && confirmation.window?.isVisible == false, "Cancel ends the whole batch")
        }
        let immediate = Task { await confirmation.confirm(items: items) }
        try? await Task.sleep(for: .milliseconds(30))
        let use = descendants(confirmation.window!.contentView!).compactMap { $0 as? NSButton }
            .first { $0.title == L10n.text("立即使用") }!
        use.performClick(nil)
        let immediateResult = await immediate.value
        precondition(immediateResult == .use, "Use now skips the countdown")
        let timeout = await confirmation.confirm(items: items, seconds: 0.1)
        precondition(timeout == .use, "No input uses the batch at the deadline")
        let interrupted = Task { await confirmation.confirm(items: items) }
        try? await Task.sleep(for: .milliseconds(30))
        interrupted.cancel()
        let interruptedResult = await interrupted.value
        precondition(interruptedResult == .interrupted, "Settings/scope/sleep interruption is not a user cancellation")
        precondition(confirmation.window?.isVisible == false, "Interrupted countdown is dismissed")
        let close = Task { await confirmation.confirm(items: items) }
        try? await Task.sleep(for: .milliseconds(30))
        confirmation.window?.performClose(nil)
        let closeResult = await close.value
        precondition(closeResult == .cancel, "Closing the frame cancels the batch")
        let many = Task { await confirmation.confirm(items: Array(repeating: items, count: 5).flatMap { $0 }) }
        try? await Task.sleep(for: .milliseconds(30))
        let list = descendants(confirmation.window!.contentView!).compactMap { $0 as? NSScrollView }.first!
        precondition(list.documentView!.bounds.height > list.bounds.height && list.hasVerticalScroller,
                     "Long account lists remain scrollable in a bounded window")
        many.cancel()
        _ = await many.value
        // Reusing the frame after cancellation must get a fresh timer and continuation.
        let reused = await confirmation.confirm(items: items, seconds: 0.1)
        precondition(reused == .use)
        print("Automatic reset dialog checks passed: bilingual account lists, use now, cancel, close, timeout, interruption and scrolling")
    }
}
