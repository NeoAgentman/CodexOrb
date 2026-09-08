import AppKit

@main
struct ResetPopoverChecks {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let suite = "CodexOrb.ResetPopoverChecks.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = OrbPanelController(defaults: defaults)
        controller.updateDefaultExpansion(true, animated: false)
        controller.show()
        defer { controller.close() }
        let anchor = NSApp.windows.first { $0.contentView is OrbView }!
        let start = ProcessInfo.processInfo.systemUptime
        let confirmation = Task { @MainActor in await controller.confirmReset(account: "fixture@example.test", recovering: false) }
        var content: ResetConfirmation?
        for _ in 0..<50 {
            await Task.yield()
            content = NSApp.windows.compactMap { $0.contentViewController?.view as? ResetConfirmation }.first
            if content?.window?.isVisible == true { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard let content, let popup = content.window, popup.isVisible else { fatalError("Confirmation did not appear promptly") }
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        precondition(elapsed < 1, "No network or refresh wait before confirmation")
        precondition(popup.frame.intersects(anchor.frame.insetBy(dx: -340, dy: -160)), "Confirmation must stay near capsule")
        precondition(!NSApp.windows.contains { $0.className.contains("NSAlert") }, "No central alert")
        // A background quota/UI refresh cannot replace a pending confirmation.
        controller.update(.loading(previous: nil))
        precondition(popup.contentViewController?.view === content)
        content.cancelButton.performClick(nil)
        let accepted = await confirmation.value
        precondition(!accepted, "Cancel must not authorize consumption")
        let cancelledTask = Task { @MainActor in await controller.confirmReset(account: "fixture", recovering: false) }
        await Task.yield()
        cancelledTask.cancel()
        let cancelledResult = await cancelledTask.value
        precondition(!cancelledResult)
        print("Anchored confirmation check passed: \(Int(elapsed * 1000)) ms, cancel and task cancellation safe")
    }
}
