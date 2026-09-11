import AppKit
import CodexOrbCore

@main
struct AccountBadgeLiveChecks {
    @MainActor
    static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        guard let account = CodexAccountStore().managedAccounts().first else {
            print("Account badge live check skipped: no CodexOrb-managed account")
            return
        }

        let suite = "CodexOrb.AccountBadgeLiveChecks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = OrbPanelController(defaults: defaults)
        defer { controller.close() }
        controller.updateAccount(account)
        controller.show()

        guard let capsule = NSApp.windows.first(where: { $0.contentView is OrbView }),
              let badgePanel = NSApp.windows.first(where: { $0.contentView is AccountBadgeView }),
              let badgeView = badgePanel.contentView as? AccountBadgeView else {
            fatalError("Account badge panel was not created")
        }
        precondition(badgePanel.isVisible, "Account badge panel should be visible")

        let screen = capsule.screen ?? NSScreen.main!
        let placement = AccountBadgeLayout.frame(
            capsuleFrame: capsule.frame,
            visibleFrame: screen.visibleFrame,
            scale: capsule.frame.height / 56)
        precondition(abs(badgePanel.frame.minX - placement.frame.minX) < 0.1,
                     "Badge horizontal placement")
        precondition(abs(badgePanel.frame.midY - placement.frame.midY) < 0.1,
                     "Badge vertical placement")
        precondition(badgeView.account?.label == account.label, "Badge account presentation")

        badgeView.onActivate?()
        guard let details = NSApp.windows.compactMap({ $0.contentViewController?.view as? AccountDetailsView }).first,
              details.window?.isVisible == true else {
            fatalError("Account details popover did not appear")
        }
        print("Account badge live check passed: panel placement, account identity and details popover")
    }
}
