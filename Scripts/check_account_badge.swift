import AppKit

@main
struct AccountBadgeChecks {
    @MainActor
    static func main() {
        func expect(_ condition: Bool, _ message: String) {
            precondition(condition, message)
        }

        let visible = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let nearRight = CGRect(x: 1370, y: 420, width: 60, height: 56)
        let rightPlacement = AccountBadgeLayout.frame(capsuleFrame: nearRight, visibleFrame: visible, scale: 1)
        expect(rightPlacement.side == .left, "Right-edge capsule should attach the badge on the left")
        expect(rightPlacement.frame.maxX <= nearRight.minX + AccountBadgeLayout.overlap,
               "Left badge must stay attached at the capsule edge")

        let nearLeft = CGRect(x: 10, y: 420, width: 60, height: 56)
        let leftPlacement = AccountBadgeLayout.frame(capsuleFrame: nearLeft, visibleFrame: visible, scale: 1)
        expect(leftPlacement.side == .left, "Account badge stays on the left")
        expect(leftPlacement.frame.maxX <= nearLeft.minX + AccountBadgeLayout.overlap,
               "Left badge must stay attached at the capsule edge")

        let info = AccountBadgeInfo(email: "hittie@example.test", workspace: "pro")
        expect(info.initial == "H", "Badge initial")
        expect(info.label == "hittie@example.test · pro", "Account label")

        _ = NSApplication.shared
        let view = AccountBadgeView(frame: NSRect(
            x: 0,
            y: 0,
            width: AccountBadgeLayout.baseSize,
            height: AccountBadgeLayout.baseSize))
        view.account = info
        expect((view.accessibilityValue() as? String) == info.label, "Badge accessibility value")

        let other = AccountBadgeInfo(identityKey: "other-account", email: "other@example.test", workspace: "team")
        var selectedIdentity: String?
        let details = AccountDetailsView(account: info, accounts: [info, other]) { selectedIdentity = $0 }
        func buttons(in view: NSView) -> [NSButton] {
            view.subviews.flatMap { subview in
                if let button = subview as? NSButton { return [button] }
                return buttons(in: subview)
            }
        }
        let accountRows = buttons(in: details)
        expect(accountRows.count == 2, "Account switcher rows")
        accountRows[1].performClick(nil)
        expect(selectedIdentity == other.identityKey, "Account switcher selection")
        print("Account badge placement and account presentation checks passed")
    }
}
