import AppKit
import CodexOrbCore

/// Cards retain their backend identity through sorting and interaction.
@MainActor
final class ResetCardsView: NSView {
    private let credits: CodexResetCredits?
    private let onConsume: (String) -> Void
    private let busy: Bool
    private var displayedCards: [CodexResetCredits.Credit?] {
        let known = Array((credits?.availableCards ?? []).prefix(max(0, credits?.availableCount ?? 0)))
        return known.map { Optional($0) } + Array(repeating: nil, count: max(0, (credits?.availableCount ?? 0) - known.count))
    }
    private func canConsume(_ index: Int) -> Bool {
        !busy && displayedCards.indices.contains(index) && displayedCards[index]?.isRedeemable() == true
    }
    private var cardTrackingArea: NSTrackingArea?
    private var hoveredCard: Int?
    private var pressedCard: Int?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area = self.cardTrackingArea { self.removeTrackingArea(area) }
        let area = NSTrackingArea(rect: self.bounds,
                                 options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                 owner: self, userInfo: nil)
        self.addTrackingArea(area)
        self.cardTrackingArea = area
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        for index in 0..<max(0, self.credits?.availableCount ?? 0) {
            if canConsume(index) { self.addCursorRect(self.ticketRect(index), cursor: .pointingHand) }
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let index = self.cardIndex(at: self.convert(event.locationInWindow, from: nil))
        if index != self.pressedCard { self.pressedCard = nil }
        self.hoveredCard = index
        self.updateCardAppearance()
    }

    private func cardIndex(at point: NSPoint) -> Int? {
        (0..<max(0, self.credits?.availableCount ?? 0)).first { self.ticketRect($0).contains(point) }
    }

    private func updateCardAppearance() {
        for label in self.subviews.compactMap({ $0 as? NSTextField }) {
            let index = label.tag
            let rect = self.ticketRect(index)
            label.frame.origin.y = rect.minY + 30 + self.cardLift(index)
        }
        self.needsDisplay = true
    }

    private func cardLift(_ index: Int) -> CGFloat {
        self.pressedCard == index ? 0 : (self.hoveredCard == index ? 2 : 0)
    }

    override func mouseEntered(with event: NSEvent) { self.mouseMoved(with: event) }

    override func mouseMoved(with event: NSEvent) {
        self.hoveredCard = self.cardIndex(at: self.convert(event.locationInWindow, from: nil))
        self.updateCardAppearance()
    }

    override func mouseExited(with event: NSEvent) {
        self.hoveredCard = nil
        self.pressedCard = nil
        self.updateCardAppearance()
    }

    override func mouseDown(with event: NSEvent) {
        self.pressedCard = self.cardIndex(at: self.convert(event.locationInWindow, from: nil))
        self.updateCardAppearance()
    }

    override func mouseUp(with event: NSEvent) {
        let released = self.cardIndex(at: self.convert(event.locationInWindow, from: nil))
        let selected = self.pressedCard
        self.pressedCard = nil
        if let selected, selected == released, canConsume(selected), let id = displayedCards[selected]?.id {
            onConsume(id)
        }
        self.hoveredCard = self.cardIndex(at: self.convert(event.locationInWindow, from: nil))
        self.updateCardAppearance()
    }

    private static let ticketWidth: CGFloat = 68
    private static let gap: CGFloat = 8

    static func expirationText(_ expiration: Date?, now: Date = Date(), compact: Bool = false) -> String {
        guard let expiration else { return compact ? L10n.text("未知") : L10n.text("期限未知") }
        let remaining = expiration.timeIntervalSince(now)
        if remaining <= 0 { return L10n.text("已到期") }
        if remaining < 3600 { return compact ? L10n.text("<1时") : L10n.text("不足1小时") }
        if remaining < 86400 { return compact ? L10n.text("\(Int(remaining / 3600))时") : L10n.text("\(Int(remaining / 3600))小时到期") }
        return compact ? L10n.text("\(Int(remaining / 86400))天") : L10n.text("\(Int(remaining / 86400))天到期")
    }

    init(credits: CodexResetCredits?, busy: Bool = false, recovery: Bool = false, onRecover: @escaping () -> Void = {}, onConsume: @escaping (String) -> Void = { _ in }) {
        self.credits = credits
        self.busy = busy || recovery
        self.onConsume = onConsume
        let count = max(0, credits?.availableCount ?? 0)
        super.init(frame: NSRect(x: 0, y: 0,
                                width: max(228, CGFloat(count) * (Self.ticketWidth + Self.gap) + 16),
                                height: recovery ? 162 : 126))
        self.setAccessibilityElement(true)
        self.setAccessibilityRole(.group)
        self.setAccessibilityLabel(L10n.text("可用重置卡片"))
        self.setAccessibilityValue(credits.map { L10n.text("\($0.availableCount)次可用重置") } ?? L10n.text("重置信息暂不可用"))
        if recovery {
            let button = NSButton(title: L10n.text("恢复上次重置操作"), target: nil, action: nil)
            button.frame = NSRect(x: 12, y: 128, width: 200, height: 26)
            button.isEnabled = !busy
            button.target = self
            button.action = #selector(recoverClicked)
            self.recoverAction = onRecover
            self.addSubview(button)
        }
        let cards = displayedCards
        for index in 0..<count {
            let expiration = cards[index]?.expiresAt
            let rect = self.ticketRect(index)
            let label = NSTextField(labelWithString: cards[index] != nil && expiration == nil ? L10n.text("长期") : Self.countdown(expiration))
            label.tag = index
            label.font = .monospacedDigitSystemFont(ofSize: expiration == nil && cards[index] != nil ? 12 : (expiration.map { $0 <= Date() } == true ? 12 : 22), weight: .medium)
            label.alignment = .center
            label.textColor = Self.color(expiration, nearest: index == 0)
            label.frame = NSRect(x: rect.minX + 2, y: rect.minY + 30, width: rect.width - 4, height: 28)
            label.setAccessibilityLabel(L10n.text("第\(index + 1)张重置卡，\(Self.expirationText(expiration))"))
            self.addSubview(label)
        }
    }

    private var recoverAction: (() -> Void)?
    @objc private func recoverClicked() { recoverAction?() }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func ticketRect(_ index: Int) -> NSRect {
        NSRect(x: 12 + CGFloat(index) * (Self.ticketWidth + Self.gap), y: 10,
               width: Self.ticketWidth, height: 82)
    }

    private static func color(_ expiration: Date?, nearest: Bool) -> NSColor {
        if let expiration, expiration.timeIntervalSinceNow < 7 * 86400 { return .systemOrange }
        return nearest ? .controlAccentColor : .labelColor
    }

    private static func countdown(_ expiration: Date?) -> String {
        guard let expiration else { return "—" }
        let remaining = expiration.timeIntervalSinceNow
        if remaining <= 0 { return L10n.text("已到期") }
        if remaining < 3600 { return L10n.text("<1时") }
        if remaining < 86400 { return L10n.text("\(Int(remaining / 3600))时") }
        return "\(Int(remaining / 86400))"
    }

    private func text(_ value: String, rect: NSRect, size: CGFloat, color: NSColor,
                      weight: NSFont.Weight = .regular, alignment: NSTextAlignment = .center) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        (value as NSString).draw(in: rect, withAttributes: [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: color, .paragraphStyle: paragraph,
        ])
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let dark = self.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let count = max(0, self.credits?.availableCount ?? 0)
        self.text(L10n.text("重置卡 · 剩余天数"), rect: NSRect(x: 12, y: 103, width: 134, height: 15),
                  size: 9, color: .labelColor, weight: .semibold, alignment: .left)
        self.text(self.credits.map { L10n.text("\($0.availableCount) 次可用") } ?? L10n.text("暂不可用"),
                  rect: NSRect(x: self.bounds.width - 82, y: 103, width: 70, height: 14),
                  size: 9, color: .secondaryLabelColor, alignment: .right)
        if count == 0 {
            self.text(self.credits == nil ? L10n.text("等待重置信息更新") : L10n.text("暂无可用重置"),
                      rect: NSRect(x: 12, y: 49, width: self.bounds.width - 24, height: 18),
                      size: 11, color: .secondaryLabelColor)
        }
        let cards = displayedCards
        let formatter = DateFormatter()
        formatter.locale = AppLanguage.load().locale
        formatter.dateFormat = "MM.dd"
        for index in 0..<count {
            let rect = self.ticketRect(index).offsetBy(dx: 0, dy: self.cardLift(index))
            let hovered = self.hoveredCard == index
            let pressed = self.pressedCard == index
            let expiration = cards[index]?.expiresAt
            let nearest = index == 0 && expiration != nil
            let accent = Self.color(expiration, nearest: nearest)
            // A soft shadow and lower rim make the ticket read as a raised control.
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(dark ? 0.28 : (hovered ? 0.16 : 0.10))
            shadow.shadowBlurRadius = pressed ? 1 : (hovered ? 5 : 3)
            shadow.shadowOffset = NSSize(width: 0, height: pressed ? -0.5 : -2)
            shadow.set()
            let silhouette = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 8, yRadius: 8)
            (dark ? NSColor(calibratedWhite: 0.22, alpha: 1) : .white).setFill()
            silhouette.fill()
            NSGraphicsContext.restoreGraphicsState()
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: rect).addClip()
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
            path.appendOval(in: NSRect(x: rect.minX - 2.5, y: rect.minY + 20, width: 5, height: 6))
            path.appendOval(in: NSRect(x: rect.maxX - 2.5, y: rect.minY + 20, width: 5, height: 6))
            path.windingRule = .evenOdd
            let base = dark ? NSColor(calibratedWhite: 0.17, alpha: 1) : .white
            base.setFill()
            path.fill()
            if nearest || hovered {
                NSColor.controlAccentColor.withAlphaComponent(dark ? (hovered ? 0.20 : 0.13) : (hovered ? 0.10 : 0.06)).setFill()
                path.fill()
            }
            if pressed {
                NSColor.black.withAlphaComponent(dark ? 0.13 : 0.04).setFill()
                path.fill()
            }
            (hovered ? NSColor.controlAccentColor.withAlphaComponent(0.55)
                : (nearest ? accent.withAlphaComponent(0.35) : NSColor.labelColor.withAlphaComponent(0.15))).setStroke()
            path.lineWidth = 0.7
            path.stroke()
            let shine = NSBezierPath()
            shine.move(to: NSPoint(x: rect.minX + 9, y: rect.maxY - 1.5))
            shine.line(to: NSPoint(x: rect.maxX - 9, y: rect.maxY - 1.5))
            NSColor.white.withAlphaComponent(dark ? 0.13 : 0.85).setStroke()
            shine.lineWidth = 0.7
            shine.stroke()
            NSGraphicsContext.restoreGraphicsState()
            let divider = NSBezierPath()
            divider.move(to: NSPoint(x: rect.minX + 9, y: rect.minY + 23))
            divider.line(to: NSPoint(x: rect.maxX - 9, y: rect.minY + 23))
            divider.setLineDash([2, 3], count: 2, phase: 0)
            divider.lineWidth = 0.5
            NSColor.labelColor.withAlphaComponent(0.13).setStroke()
            divider.stroke()
            self.text(nearest ? L10n.text("最近到期") : "", rect: NSRect(x: rect.minX, y: rect.minY + 63, width: rect.width, height: 13),
                      size: 7, color: nearest ? accent : .tertiaryLabelColor, weight: .medium)
            self.text(expiration.map { formatter.string(from: $0) } ?? (cards[index] == nil ? L10n.text("日期待更新") : L10n.text("无到期时间")),
                      rect: NSRect(x: rect.minX, y: rect.minY + 6, width: rect.width, height: 11),
                      size: 7.5, color: .secondaryLabelColor)
        }
    }
}

@MainActor
final class ResetCardsScrollView: NSScrollView {
    var onClose: (() -> Void)?
    override var acceptsFirstResponder: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        self.onClose?()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            self.cancelOperation(nil)
        } else {
            super.keyDown(with: event)
        }
    }
}
