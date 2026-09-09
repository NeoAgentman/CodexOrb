import AppKit
import CodexOrbCore

struct AccountBadgeInfo: Equatable {
    let email: String
    let workspace: String

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
    var account: AccountBadgeInfo? {
        didSet {
            self.needsDisplay = true
            self.updateAccessibility()
        }
    }
    var onActivate: (() -> Void)?

    private var isPressed = false

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
        let rect = self.bounds.insetBy(dx: 2.5, dy: 2.5)
        let radius = rect.height / 2
        let colors = CapsuleSurfaceColors.resolved(for: self.effectiveAppearance)
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        colors.drawBackground(in: rect, cornerRadius: radius, context: context)

        let accentRing = rect.insetBy(dx: 3.75, dy: 3.75)
        context.saveGState()
        context.setLineCap(.round)
        context.setLineWidth(1.15)
        context.setStrokeColor(
            NSColor.controlAccentColor
                .withAlphaComponent(self.isPressed ? 0.68 : 0.50)
                .cgColor)
        context.strokeEllipse(in: accentRing)
        context.restoreGState()

        if self.isPressed {
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 1.5, dy: 1.5), xRadius: radius - 1.5, yRadius: radius - 1.5)
            NSColor.controlAccentColor.withAlphaComponent(0.14).setFill()
            path.fill()
        }

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let fontSize = min(15, max(10, rect.height * 0.44))
        (account.initial as NSString).draw(
            in: rect.offsetBy(dx: 0, dy: -fontSize * 0.34),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
                .foregroundColor: colors.primaryText,
                .paragraphStyle: paragraph,
            ])
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
final class AccountDetailsView: NSView {
    init(account: AccountBadgeInfo) {
        super.init(frame: NSRect(x: 0, y: 0, width: 268, height: 92))
        self.setAccessibilityElement(true)
        self.setAccessibilityRole(.group)
        self.setAccessibilityLabel(L10n.text("当前账号"))
        self.setAccessibilityValue(account.label)

        let title = self.label(
            L10n.text("当前账号"),
            frame: NSRect(x: 16, y: 65, width: 236, height: 18),
            font: .systemFont(ofSize: 11, weight: .semibold),
            color: .secondaryLabelColor)
        self.addSubview(title)

        let email = self.label(
            account.email,
            frame: NSRect(x: 16, y: 37, width: 236, height: 24),
            font: .systemFont(ofSize: 14, weight: .medium),
            color: .labelColor)
        email.lineBreakMode = .byTruncatingMiddle
        self.addSubview(email)

        let workspace = self.label(
            L10n.text("账号类型：\(account.workspace)"),
            frame: NSRect(x: 16, y: 14, width: 236, height: 16),
            font: .systemFont(ofSize: 11, weight: .regular),
            color: .secondaryLabelColor)
        self.addSubview(workspace)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func label(_ text: String, frame: NSRect, font: NSFont, color: NSColor) -> NSTextField {
        let result = NSTextField(labelWithString: text)
        result.font = font
        result.textColor = color
        result.usesSingleLineMode = true
        result.alignment = .left
        result.frame = frame
        return result
    }
}
