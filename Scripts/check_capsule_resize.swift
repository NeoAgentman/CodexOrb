import AppKit

@MainActor
private final class InteractionProbe: OrbViewDelegate {
    var resized = 0
    var quotaDetails = 0
    var tokenDetails = 0
    var cards = 0
    var moved = 0
    func orbView(_ view: OrbView, didBeginResizing edge: CapsuleGeometry.Edge) { resized += 1 }
    func orbView(_ view: OrbView, didResizeBy delta: CGPoint) {}
    func orbViewDidFinishResizing(_ view: OrbView) {}
    func orbView(_ view: OrbView, didDragBy delta: CGPoint) { moved += 1 }
    func orbViewDidFinishDragging(_ view: OrbView) {}
    func orbView(_ view: OrbView, didChangeHover isHovering: Bool) {}
    func orbViewDidRequestQuotaDetails(_ view: OrbView) { quotaDetails += 1 }
    func orbViewDidRequestTokenDetails(_ view: OrbView) { tokenDetails += 1 }
    func orbViewDidRequestResetCards(_ view: OrbView) { cards += 1 }
    func orbViewDidRequestRefresh(_ view: OrbView) {}
    func orbViewDidRequestSettings(_ view: OrbView) {}
    func orbViewDidRequestQuit(_ view: OrbView) {}
}

@main
struct CapsuleResizeChecks {
    @MainActor
    static func main() {
        func expect(_ condition: Bool, _ message: String) {
            precondition(condition, message)
        }
        let start = CGRect(x: 200, y: 200, width: 176, height: 56)
        for edge: CapsuleGeometry.Edge in [.left, .right, .top, .bottom, [.left, .top], [.right, .bottom]] {
            let delta = CGPoint(x: edge.contains(.left) ? -10000 : edge.contains(.right) ? 10000 : 0,
                                y: edge.contains(.bottom) ? -10000 : edge.contains(.top) ? 10000 : 0)
            let big = CapsuleGeometry.resizedFrame(start: start, delta: delta, edge: edge, expanded: true)
            expect(big.size == CGSize(width: 264, height: 84), "Maximum size")
            if edge.contains(.left) { expect(big.maxX == start.maxX, "Left edge anchor") }
            if edge.contains(.right) { expect(big.minX == start.minX, "Right edge anchor") }
            if edge.contains(.bottom) { expect(big.maxY == start.maxY, "Bottom edge anchor") }
            if edge.contains(.top) { expect(big.minY == start.minY, "Top edge anchor") }
            let small = CapsuleGeometry.resizedFrame(start: big, delta: CGPoint(x: -delta.x, y: -delta.y), edge: edge, expanded: true)
            expect(small.size == start.size, "Minimum size")
        }
        expect(!CapsuleGeometry.resizeEdge(at: CGPoint(x: 12, y: 10), bounds: start.offsetBy(dx: -200, dy: -200), scale: 1).isEmpty,
               "Curved visible edge is resizable")
        expect(CapsuleGeometry.scale(.nan) == 1, "Invalid saved scale")
        expect(CapsuleGeometry.scale(9) == 1.5, "Oversized saved scale")
        let limited = CapsuleGeometry.resizedFrame(start: start, delta: CGPoint(x: 1000, y: 0), edge: .right,
                                                   expanded: true, maximumScale: 1.2)
        expect(abs(limited.height - 67.2) < 0.001, "Screen size cap")

        _ = NSApplication.shared
        let suite = "CodexOrb.ResizeChecks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = OrbPanelController(defaults: defaults)
        guard let panel = NSApp.windows.last(where: { $0.contentView is OrbView }),
              let view = panel.contentView as? OrbView else { fatalError("Missing panel") }
        controller.updateDefaultExpansion(true, animated: false)
        func pointerEvent(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                               windowNumber: panel.windowNumber, context: nil, eventNumber: 0,
                               clickCount: 1, pressure: 1)!
        }
        view.mouseMoved(with: pointerEvent(.mouseMoved, CGPoint(x: 170, y: 28)))
        expect(NSCursor.current.isEqual(NSCursor.resizeLeftRight), "Visible edge resize cursor")
        view.mouseDown(with: pointerEvent(.leftMouseDown, CGPoint(x: 170, y: 28)))
        view.mouseDragged(with: pointerEvent(.leftMouseDragged, CGPoint(x: 210, y: 28)))
        expect(abs(panel.frame.width - 216) < 0.001, "Drag must use event position, not global cursor")
        view.mouseUp(with: pointerEvent(.leftMouseUp, CGPoint(x: 210, y: 28)))
        controller.orbView(view, didBeginResizing: .right)
        controller.orbView(view, didResizeBy: CGPoint(x: -10000, y: 0))
        controller.orbViewDidFinishResizing(view)
        controller.orbView(view, didBeginResizing: .right)
        controller.orbView(view, didResizeBy: CGPoint(x: 10000, y: 0))
        expect(panel.frame.size == CGSize(width: 264, height: 84), "Expanded resize integration")
        expect(view.bounds.size == CGSize(width: 176, height: 56), "Logical drawing and hit coordinates")
        let rect = view.convert(view.resetCardsRect, to: nil)
        expect(abs(rect.width - 66) < 0.001, "Popover anchor scales with hit area")
        controller.orbViewDidFinishResizing(view)
        expect(defaults.double(forKey: "CodexOrb.capsuleScale") == 1.5, "Scale persisted")
        let probe = InteractionProbe()
        view.delegate = probe
        func click(_ point: CGPoint, drag: Bool = false) {
            let location = view.convert(point, to: nil)
            func event(_ type: NSEvent.EventType) -> NSEvent {
                NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: 0,
                                   windowNumber: panel.windowNumber, context: nil, eventNumber: 0,
                                   clickCount: 1, pressure: 1)!
            }
            view.mouseDown(with: event(.leftMouseDown))
            if drag { view.mouseDragged(with: event(.leftMouseDragged)) }
            view.mouseUp(with: event(.leftMouseUp))
        }
        click(CGPoint(x: 170, y: 28), drag: true)
        expect(probe.resized == 1 && probe.cards == 0 && probe.moved == 0,
               "Edge resize must not move or click content")
        click(CGPoint(x: 75, y: 28))
        expect(probe.cards == 1, "Scaled card click")
        click(CGPoint(x: 130, y: 28))
        expect(probe.tokenDetails == 1, "Scaled token single click opens token details")
        click(CGPoint(x: 30, y: 28))
        expect(probe.quotaDetails == 1, "Scaled ring single click opens quota details")
        view.delegate = controller
        controller.orbView(view, didChangeHover: false)
        controller.updateDefaultExpansion(false, animated: false)
        expect(panel.frame.size == CGSize(width: 90, height: 84), "Collapsed scale retained")
        let screen = panel.screen!
        controller.orbView(view, didDragBy: CGPoint(x: 0, y: screen.frame.minY - panel.frame.minY))
        controller.orbViewDidFinishDragging(view)
        expect(abs(panel.frame.minY - screen.frame.minY) < 0.001, "Dock space remains available")
        controller.close()
        let restored = OrbPanelController(defaults: defaults)
        let restoredPanel = NSApp.windows.last(where: { $0.contentView is OrbView })!
        expect(restoredPanel.frame.size == CGSize(width: 90, height: 84), "Scale restored")
        restored.close()
        print("Capsule resize geometry, scaling, anchor, persistence and restoration checks passed")
    }
}
