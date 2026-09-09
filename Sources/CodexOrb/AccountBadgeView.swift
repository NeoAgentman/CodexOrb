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
    private static let cardWidth: CGFloat = 300
    private static let horizontalPadding: CGFloat = 16
    private static let rowHeight: CGFloat = 28
    private let currentAccount: AccountBadgeInfo
    private let accounts: [AccountBadgeInfo]
    private let canSwitch: Bool
    private let onSelect: (String) -> Void

    init(
        account: AccountBadgeInfo,
        accounts: [AccountBadgeInfo] = [],
        canSwitch: Bool = true,
        onSelect: @escaping (String) -> Void = { _ in })
    {
        self.currentAccount = account
        self.accounts = accounts
        self.canSwitch = canSwitch
        self.onSelect = onSelect
        let height: CGFloat
        if accounts.count > 1 {
            let itemHeights: CGFloat = 18 + 24 + 16 + 1 + 16 + CGFloat(accounts.count) * Self.rowHeight
            let gaps = CGFloat(accounts.count + 4) * 5
            height = 28 + itemHeights + gaps
        } else {
            height = 96
        }
        super.init(frame: NSRect(x: 0, y: 0, width: Self.cardWidth, height: height))
        self.setAccessibilityElement(true)
        self.setAccessibilityRole(.group)
        self.setAccessibilityLabel(L10n.text("当前账号"))
        self.setAccessibilityValue(account.label)

        self.buildContent()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func buildContent() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        self.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: self.leadingAnchor, constant: Self.horizontalPadding),
            stack.trailingAnchor.constraint(equalTo: self.trailingAnchor, constant: -Self.horizontalPadding),
            stack.topAnchor.constraint(equalTo: self.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: self.bottomAnchor, constant: -14),
        ])

        let title = self.label(
            L10n.text("当前账号"),
            height: 18,
            font: .systemFont(ofSize: 11, weight: .semibold),
            color: .secondaryLabelColor)
        stack.addArrangedSubview(title)

        let email = self.label(
            self.currentAccount.email,
            height: 24,
            font: .systemFont(ofSize: 14, weight: .medium),
            color: .labelColor)
        email.lineBreakMode = .byTruncatingMiddle
        stack.addArrangedSubview(email)

        let workspace = self.label(
            L10n.text("账号类型：\(self.currentAccount.workspace)"),
            height: 16,
            font: .systemFont(ofSize: 11, weight: .regular),
            color: .secondaryLabelColor)
        stack.addArrangedSubview(workspace)

        guard self.accounts.count > 1 else { return }
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.widthAnchor.constraint(equalToConstant: Self.cardWidth - 2 * Self.horizontalPadding).isActive = true
        separator.heightAnchor.constraint(equalToConstant: 1).isActive = true
        stack.addArrangedSubview(separator)

        let switchTitle = self.label(
            L10n.text("切换账号"),
            height: 16,
            font: .systemFont(ofSize: 11, weight: .semibold),
            color: .secondaryLabelColor)
        stack.addArrangedSubview(switchTitle)

        for account in self.accounts {
            let row = AccountRowButton(
                account: account,
                selected: account.identityKey == self.currentAccount.identityKey,
                enabled: self.canSwitch)
            row.target = self
            row.action = #selector(self.accountRowClicked(_:))
            row.translatesAutoresizingMaskIntoConstraints = false
            row.widthAnchor.constraint(equalToConstant: Self.cardWidth - 2 * Self.horizontalPadding).isActive = true
            row.heightAnchor.constraint(equalToConstant: Self.rowHeight).isActive = true
            stack.addArrangedSubview(row)
        }
    }

    private func label(_ text: String, height: CGFloat, font: NSFont, color: NSColor) -> NSTextField {
        let result = NSTextField(labelWithString: text)
        result.font = font
        result.textColor = color
        result.usesSingleLineMode = true
        result.alignment = .left
        result.translatesAutoresizingMaskIntoConstraints = false
        result.widthAnchor.constraint(equalToConstant: Self.cardWidth - 2 * Self.horizontalPadding).isActive = true
        result.heightAnchor.constraint(equalToConstant: height).isActive = true
        return result
    }

    @objc private func accountRowClicked(_ sender: Any?) {
        guard self.canSwitch, let row = sender as? AccountRowButton,
              row.identityKey != self.currentAccount.identityKey else { return }
        self.onSelect(row.identityKey)
    }

    private final class AccountRowButton: NSButton {
        let identityKey: String

        init(account: AccountBadgeInfo, selected: Bool, enabled: Bool) {
            self.identityKey = account.identityKey
            super.init(frame: .zero)
            self.title = account.label
            self.font = .systemFont(ofSize: 12, weight: selected ? .medium : .regular)
            self.alignment = .left
            self.isBordered = false
            self.bezelStyle = .inline
            self.setButtonType(.momentaryPushIn)
            self.contentTintColor = selected ? .labelColor : .secondaryLabelColor
            self.image = selected
                ? NSImage(systemSymbolName: "checkmark", accessibilityDescription: L10n.text("当前账号"))
                : nil
            self.imagePosition = .imageLeading
            self.imageScaling = .scaleProportionallyDown
            self.isEnabled = enabled
            self.setAccessibilityElement(true)
            self.setAccessibilityRole(.button)
            self.setAccessibilityLabel(account.label)
            self.setAccessibilityValue(selected ? L10n.text("当前账号") : "")
            self.cell?.lineBreakMode = .byTruncatingTail
            self.cell?.usesSingleLineMode = true
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
    }
}
