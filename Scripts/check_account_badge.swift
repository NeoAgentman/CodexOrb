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
        expect(leftPlacement.side == .right, "Left-edge capsule should attach the badge on the right")
        expect(leftPlacement.frame.minX >= nearLeft.maxX - AccountBadgeLayout.overlap,
               "Right badge must stay attached at the capsule edge")

        let info = AccountBadgeInfo(email: "hittie@example.test", workspace: "pro")
        expect(info.initial == "H", "Badge initial")
        expect(info.label == "hittie@example.test · pro", "Account label")

        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let view = AccountBadgeView(frame: NSRect(
            x: 0,
            y: 0,
            width: AccountBadgeLayout.baseSize,
            height: AccountBadgeLayout.baseSize))
        view.account = info
        expect((view.accessibilityValue() as? String) == info.label, "Badge accessibility value")

        let panel = AccountBadgePanel(contentRect: NSRect(x: 200, y: 200, width: 30, height: 30),
                                      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.acceptsMouseMovedEvents = true
        panel.contentView = view
        panel.orderFrontRegardless()
        defer { panel.close() }
        view.updateTrackingAreas()
        let options = view.trackingAreas.first!.options
        expect(options.contains([.mouseMoved, .cursorUpdate, .activeAlways]), "Badge must track inactive cursor updates")
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        func event(_ type: NSEvent.EventType) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: NSPoint(x: 15, y: 15), modifierFlags: [],
                               timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                               context: nil, eventNumber: 0, clickCount: 1, pressure: 0)!
        }
        view.mouseEntered(with: event(.mouseMoved))
        for _ in 0..<3 {
            NSCursor.arrow.set()
            view.mouseMoved(with: event(.mouseMoved))
            expect(NSCursor.current.isEqual(NSCursor.pointingHand), "Badge movement must restore hand cursor")
            NSCursor.arrow.set()
            view.cursorUpdate(with: event(.mouseMoved))
            // WindowServer updates asynchronously; allow it to apply the cursor request.
            for _ in 0..<10 {
                if let cursor = NSCursor.currentSystem,
                   cursor.hotSpot == NSCursor.pointingHand.hotSpot,
                   cursor.image.size == NSCursor.pointingHand.image.size { break }
                Thread.sleep(forTimeInterval: 0.01)
            }
            guard let systemCursor = NSCursor.currentSystem else { fatalError("System cursor unavailable") }
            expect(systemCursor.hotSpot == NSCursor.pointingHand.hotSpot
                   && systemCursor.image.size == NSCursor.pointingHand.image.size,
                   "Inactive badge must set the actual system hand cursor")
        }
        expect(NSWorkspace.shared.frontmostApplication?.processIdentifier == frontmost,
               "Badge hover must not activate the application")
        var activations = 0
        view.onActivate = { activations += 1 }
        view.mouseDown(with: event(.leftMouseDown))
        view.mouseUp(with: event(.leftMouseUp))
        expect(activations == 1, "Badge click must still open account details")
        view.mouseExited(with: event(.mouseMoved))
        expect(NSCursor.current.isEqual(NSCursor.arrow), "Leaving the badge restores the arrow")
        view.mouseEntered(with: event(.mouseMoved))
        view.account = nil
        expect(NSCursor.current.isEqual(NSCursor.arrow), "Removing the account clears the hand cursor")
        view.mouseExited(with: event(.mouseMoved))
        view.account = info

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
        print("Account badge checks passed: placement, background system hand cursor, exit, removal and clicks")
    }
}
