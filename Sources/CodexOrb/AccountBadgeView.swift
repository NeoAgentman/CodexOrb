import AppKit
import CodexOrbCore

struct AccountBadgeInfo: Equatable {
    let identityKey: String
    let email: String
    let workspace: String

    init(identityKey: String = "", email: String, workspace: String) {
        self.identityKey = identityKey
        self.email = email
        self.workspace = workspace
    }

    init(account: CodexAccount) {
        self.init(identityKey: account.identityKey, email: account.email, workspace: account.workspace)
    }

    var initial: String {
        self.email.first.map { String($0).uppercased() } ?? "?"
    }

    var label: String {
        "\(self.email) · \(self.workspace)"
    }
}

enum AccountBadgeSide: Equatable {
    case left
    case right
}

enum AccountBadgeLayout {
    static let baseSize: CGFloat = 30
    static let overlap: CGFloat = 1
    static let edgeGap: CGFloat = 4

    static func badgeSize(scale: CGFloat) -> CGFloat {
        Self.baseSize * min(1.5, max(1, scale))
    }

    static func side(capsuleFrame: CGRect, visibleFrame: CGRect, badgeSize: CGFloat) -> AccountBadgeSide {
        let requiredSpace = badgeSize + Self.edgeGap - Self.overlap
        let leftSpace = capsuleFrame.minX - visibleFrame.minX
        let rightSpace = visibleFrame.maxX - capsuleFrame.maxX
        if rightSpace < requiredSpace, leftSpace >= requiredSpace { return .left }
        if leftSpace < requiredSpace, rightSpace >= requiredSpace { return .right }
        return rightSpace >= leftSpace ? .right : .left
    }

    static func frame(capsuleFrame: CGRect, visibleFrame: CGRect, scale: CGFloat) -> (side: AccountBadgeSide, frame: CGRect) {
        let size = Self.badgeSize(scale: scale)
        let side = Self.side(capsuleFrame: capsuleFrame, visibleFrame: visibleFrame, badgeSize: size)
        let x = side == .left
            ? capsuleFrame.minX - size + Self.overlap
            : capsuleFrame.maxX - Self.overlap
        let y = capsuleFrame.midY - size / 2
        return (side, CGRect(x: x, y: y, width: size, height: size))
    }
}

@MainActor
final class AccountBadgeView: NSView {
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        self.needsDisplay = true
    }

    var account: AccountBadgeInfo? {
        didSet {
            self.needsDisplay = true
            self.updateAccessibility()
        }
    }
    var onActivate: (() -> Void)?

    var isPopoverShown = false { didSet { self.needsDisplay = true } }
    private var isHovered = false
    private var isPressed = false

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        self.trackingAreas.forEach { self.removeTrackingArea($0) }
        self.addTrackingArea(NSTrackingArea(rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        self.isHovered = true
        self.needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        self.isHovered = false
        self.isPressed = false
        self.needsDisplay = true
    }

    override func accessibilityPerformPress() -> Bool {
        guard self.account != nil else { return false }
        self.onActivate?()
        return true
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        self.wantsLayer = true
        self.layer?.masksToBounds = false
        self.setAccessibilityElement(true)
        self.setAccessibilityRole(.button)
        self.updateAccessibility()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard self.account != nil else { return }
        self.addCursorRect(self.bounds, cursor: .pointingHand)
    }

    override func mouseDown(with event: NSEvent) {
        _ = event
        guard self.account != nil else { return }
        self.isPressed = true
        self.needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let activated = self.isPressed && self.bounds.contains(self.convert(event.locationInWindow, from: nil))
        self.isPressed = false
        self.needsDisplay = true
        if activated { self.onActivate?() }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let account = self.account else { return }
        let rect = self.bounds.insetBy(dx: self.isPressed ? 3 : 2.5, dy: self.isPressed ? 3 : 2.5)
        AccountAvatar.draw(initial: account.initial, in: rect, appearance: self.effectiveAppearance,
                           emphasized: self.isPopoverShown || self.isPressed, hovered: self.isHovered)
    }

    private func updateAccessibility() {
        self.setAccessibilityLabel(L10n.text("当前账号"))
        self.setAccessibilityValue(self.account?.label ?? L10n.text("未登录或账号不可用"))
    }
}

final class AccountBadgePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
private enum AccountAvatar {
    static func draw(initial: String, in rect: NSRect, appearance: NSAppearance,
                     emphasized: Bool = false, hovered: Bool = false) {
        let colors = CapsuleSurfaceColors.resolved(for: appearance)
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        colors.drawBackground(in: rect, cornerRadius: rect.height / 2, context: context)
        let outline = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
        if emphasized || hovered {
            (emphasized ? NSColor.controlAccentColor.withAlphaComponent(0.10)
                        : NSColor.labelColor.withAlphaComponent(0.04)).setFill()
            outline.fill()
        }
        colors.primaryText.withAlphaComponent(0.12).setStroke()
        outline.lineWidth = 0.5
        outline.stroke()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: min(15, rect.height * 0.43), weight: .medium),
            .foregroundColor: colors.primaryText,
        ]
        let text = initial as NSString
        let size = text.size(withAttributes: attributes)
        text.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
                  withAttributes: attributes)
    }
}

@MainActor
final class AccountDetailsView: NSView {
    private static let cardWidth: CGFloat = 288
    private let currentAccount: AccountBadgeInfo
    private let accounts: [AccountBadgeInfo]
    private let canSwitch: Bool
    private let onSelect: (String) -> Void

    init(account: AccountBadgeInfo, accounts: [AccountBadgeInfo] = [], canSwitch: Bool = true,
         onSelect: @escaping (String) -> Void = { _ in }) {
        self.currentAccount = account
        self.accounts = accounts.count > 1 ? accounts : [account]
        self.canSwitch = canSwitch
        self.onSelect = onSelect
        let height = 48 + CGFloat(self.accounts.count) * 46 + CGFloat(self.accounts.count - 1) * 4
        super.init(frame: NSRect(x: 0, y: 0, width: Self.cardWidth, height: height))
        self.setAccessibilityElement(true)
        self.setAccessibilityRole(.group)
        self.setAccessibilityLabel(L10n.text("当前账号"))
        self.setAccessibilityValue(account.label)
        self.buildContent()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    var onClose: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { self.onClose?() }

    private func buildContent() {
        let multiple = self.accounts.count > 1
        let title = NSTextField(labelWithString: L10n.text(multiple ? "切换账号" : "当前账号"))
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.textColor = .secondaryLabelColor
        title.frame = NSRect(x: 16, y: 13, width: 256, height: 17)
        self.addSubview(title)
        for (index, account) in self.accounts.enumerated() {
            let row = AccountRowButton(account: account,
                selected: account.identityKey == self.currentAccount.identityKey,
                enabled: self.canSwitch, multiple: multiple)
            row.frame = NSRect(x: 12, y: 36 + CGFloat(index) * 50, width: 264, height: 46)
            row.target = self
            row.action = #selector(self.accountRowClicked(_:))
            self.addSubview(row)
        }
    }

    @objc private func accountRowClicked(_ sender: Any?) {
        guard self.canSwitch, let row = sender as? AccountRowButton,
              row.identityKey != self.currentAccount.identityKey else { return }
        self.onSelect(row.identityKey)
    }

    private final class AccountRowButton: NSButton {
        let identityKey: String
        private let account: AccountBadgeInfo
        private let selected: Bool
        private let multiple: Bool
        private var hovered = false

        init(account: AccountBadgeInfo, selected: Bool, enabled: Bool, multiple: Bool) {
            self.identityKey = account.identityKey
            self.account = account
            self.selected = selected
            self.multiple = multiple
            super.init(frame: .zero)
            self.title = account.label
            self.isBordered = false
            self.setButtonType(.momentaryPushIn)
            self.isEnabled = enabled
            self.setAccessibilityLabel(account.label)
            self.setAccessibilityValue(selected ? L10n.text("当前账号") : "")
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override var isFlipped: Bool { true }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            self.trackingAreas.forEach { self.removeTrackingArea($0) }
            self.addTrackingArea(NSTrackingArea(rect: .zero,
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        }
        override func mouseEntered(with event: NSEvent) { self.hovered = true; self.needsDisplay = true }
        override func mouseExited(with event: NSEvent) { self.hovered = false; self.needsDisplay = true }

        override func draw(_ dirtyRect: NSRect) {
            let active = self.isEnabled && (self.hovered || self.isHighlighted)
            if self.multiple && (self.selected || active) {
                let color = self.selected ? NSColor.controlAccentColor : NSColor.labelColor
                color.withAlphaComponent(self.isHighlighted ? 0.14 : (active ? 0.10 : 0.06)).setFill()
                NSBezierPath(roundedRect: self.bounds, xRadius: 9, yRadius: 9).fill()
            }
            AccountAvatar.draw(initial: self.account.initial, in: NSRect(x: 8, y: 9, width: 28, height: 28),
                               appearance: self.effectiveAppearance)
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingMiddle
            let opacity: CGFloat = self.isEnabled ? 1 : 0.5
            (self.account.email as NSString).draw(in: NSRect(x: 44, y: 7, width: 190, height: 17), withAttributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: self.selected ? .medium : .regular),
                .foregroundColor: NSColor.labelColor.withAlphaComponent(opacity), .paragraphStyle: paragraph])
            (self.account.workspace as NSString).draw(in: NSRect(x: 44, y: 25, width: 190, height: 14), withAttributes: [
                .font: NSFont.systemFont(ofSize: 10),
                .foregroundColor: (self.isEnabled ? NSColor.secondaryLabelColor : NSColor.tertiaryLabelColor), .paragraphStyle: paragraph])
            if self.selected && self.multiple {
                NSColor.controlAccentColor.withAlphaComponent(opacity).setStroke()
                let mark = NSBezierPath()
                mark.move(to: NSPoint(x: 243, y: 23))
                mark.line(to: NSPoint(x: 247, y: 27))
                mark.line(to: NSPoint(x: 254, y: 19))
                mark.lineWidth = 1.6
                mark.lineCapStyle = .round
                mark.lineJoinStyle = .round
                mark.stroke()
            }
            if self.window?.firstResponder === self {
                NSColor.keyboardFocusIndicatorColor.setStroke()
                let focus = NSBezierPath(roundedRect: self.bounds.insetBy(dx: 1, dy: 1), xRadius: 8, yRadius: 8)
                focus.lineWidth = 2
                focus.stroke()
            }
        }
    }
}
