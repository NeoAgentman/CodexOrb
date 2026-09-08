import AppKit
import CodexOrbCore

@main
struct ResetCardChecks {
    @MainActor static func main() {
        _ = NSApplication.shared
        let cards = CodexResetCredits(availableCount: 4, credits: [
            .init(id: "later", status: "available", resetType: "codexRateLimits", expiresAt: Date().addingTimeInterval(90000)),
            .init(id: "first", status: "available", resetType: "codexRateLimits", expiresAt: Date().addingTimeInterval(80000)),
            .init(id: "expired", status: "available", resetType: "codexRateLimits", expiresAt: Date().addingTimeInterval(-100)),
        ])
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200), styleMask: [], backing: .buffered, defer: false)
        var selected: [String] = []
        func click(_ view: ResetCardsView, x: CGFloat, releasedX: CGFloat? = nil) {
            func event(_ type: NSEvent.EventType, _ x: CGFloat) -> NSEvent {
                NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: 40), modifierFlags: [], timestamp: 0,
                                   windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            }
            view.mouseDown(with: event(.leftMouseDown, x))
            view.mouseUp(with: event(.leftMouseUp, releasedX ?? x))
        }
        let view = ResetCardsView(credits: cards, onConsume: { selected.append($0) })
        window.contentView = view
        click(view, x: 30) // expired
        precondition(selected.isEmpty)
        click(view, x: 110) // first available, sorted alongside its ID
        precondition(selected == ["first"])
        click(view, x: 185, releasedX: 280) // release outside selected card
        click(view, x: 270) // count-only placeholder
        precondition(selected == ["first"])
        let busy = ResetCardsView(credits: cards, busy: true, onConsume: { selected.append($0) })
        window.contentView = busy
        click(busy, x: 110)
        precondition(selected == ["first"])
        let recovery = ResetCardsView(credits: cards, recovery: true, onConsume: { selected.append($0) })
        window.contentView = recovery
        click(recovery, x: 110)
        precondition(selected == ["first"])
        var damagedRecordActions = 0
        let damaged = ResetCardsView(
            credits: cards,
            damagedRecovery: true,
            onDiscardDamaged: { damagedRecordActions += 1 },
            onConsume: { selected.append($0) })
        window.contentView = damaged
        click(damaged, x: 110)
        precondition(selected == ["first"], "Damaged pending state disables card consumption")
        let damagedButton = damaged.subviews.compactMap { $0 as? NSButton }.first
        precondition(damagedButton?.title == L10n.text("处理损坏的重置记录"))
        damagedButton?.performClick(nil)
        precondition(damagedRecordActions == 1, "Damaged pending state has a separate handling action")
        var sends = 0
        var responses: [Bool] = []
        let confirmation = ResetConfirmation(account: "fixture@example.test", recovering: false) { confirmed in
            responses.append(confirmed)
            if confirmed { sends += 1 }
        }
        precondition(confirmation.accountLabel.stringValue == "fixture@example.test")
        precondition(confirmation.subviews.compactMap { $0 as? NSTextField }.count == 2)
        precondition(confirmation.confirmButton.keyEquivalent.isEmpty)
        precondition(confirmation.cancelButton.keyEquivalent == "\r")
        confirmation.cancelButton.performClick(nil)
        confirmation.confirmButton.performClick(nil)
        precondition(sends == 0 && responses == [false], "Cancel cannot consume or subsequently confirm")
        let affirmative = ResetConfirmation(account: "fixture", recovering: false) { if $0 { sends += 1 } }
        affirmative.confirmButton.performClick(nil)
        affirmative.confirmButton.performClick(nil)
        precondition(sends == 1, "Affirmative confirmation fires once")
        let escape = ResetConfirmation(account: "fixture", recovering: false) { if $0 { sends += 1 } }
        escape.cancelOperation(nil)
        precondition(sends == 1, "Escape cannot consume")
        print("Reset card UI checks passed: ID binding, disabled cards, drag-out, pending recovery, damaged record handling, confirmation and cancel")
    }
}
