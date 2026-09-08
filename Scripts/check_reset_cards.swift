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
        var sends = 0
        for response in [NSApplication.ModalResponse.alertSecondButtonReturn, .abort, .cancel] {
            if ResetConfirmation.confirm(accountLabel: "fixture@example.test", detail: "Use 1 card", recovering: false, present: { alert in
                precondition(alert.informativeText.contains("fixture@example.test"))
                precondition(alert.buttons[0].keyEquivalent.isEmpty)
                precondition(alert.buttons[1].keyEquivalent == "\r")
                return response
            }) { sends += 1 }
        }
        precondition(sends == 0, "Cancel, dismiss and abort must not authorize consumption")
        if ResetConfirmation.confirm(accountLabel: "fixture", detail: "Use 1", recovering: false,
                                     present: { _ in .alertFirstButtonReturn }) { sends += 1 }
        precondition(sends == 1, "Only affirmative confirmation authorizes a send")
        print("Reset card UI checks passed: ID binding, disabled cards, drag-out, pending recovery, confirmation and cancel")
    }
}
