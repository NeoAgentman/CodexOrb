import AppKit
import CodexOrbCore

/// A short notice that follows the capsule without taking focus until clicked.
@MainActor
final class CommitmentBubble: NSPanel {
    private let bubbleView = CommitmentBubbleView()
    private var dismissTask: Task<Void, Never>?
    var onActivate: (() -> Void)? {
        get { self.bubbleView.onActivate }
        set { self.bubbleView.onActivate = newValue }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init() {
        super.init(contentRect: CGRect(x: 0, y: 0, width: 112, height: 38),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        self.contentView = self.bubbleView
        self.level = .floating
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        self.backgroundColor = .clear
        self.isOpaque = false
        self.hasShadow = true
        self.hidesOnDeactivate = false
        self.isReleasedWhenClosed = false
        self.isExcludedFromWindowsMenu = true
    }

    func show(beside anchor: NSWindow, duration: Duration) {
        self.dismissTask?.cancel()
        self.bubbleView.update()
        self.setContentSize(self.bubbleView.noticeSize)
        self.appearance = anchor.effectiveAppearance
        if self.parent !== anchor { anchor.addChildWindow(self, ordered: .above) }
        self.reposition(beside: anchor)
        self.orderFrontRegardless()
        self.dismissTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: duration) }
            catch { return }
            self?.dismiss()
        }
    }

    func reposition(beside anchor: NSWindow) {
        let visible = (anchor.screen ?? NSScreen.main)?.visibleFrame ?? anchor.frame
        let bounds = visible.insetBy(dx: 6, dy: 6)
        let gap: CGFloat = 4
        let above = bounds.maxY - anchor.frame.maxY
        let below = anchor.frame.minY - bounds.minY
        let isAbove = above >= self.frame.height + gap || above >= below
        let x = min(max(anchor.frame.midX - self.frame.width / 2, bounds.minX), bounds.maxX - self.frame.width)
        let preferredY = isAbove ? anchor.frame.maxY + gap : anchor.frame.minY - gap - self.frame.height
        let y = min(max(preferredY, bounds.minY), bounds.maxY - self.frame.height)
        self.bubbleView.pointsDown = isAbove
        self.bubbleView.arrowX = min(max(anchor.frame.midX - x, 18), self.frame.width - 18)
        self.setFrameOrigin(CGPoint(x: x, y: y))
    }

    func dismiss() {
        self.dismissTask?.cancel()
        self.dismissTask = nil
        self.parent?.removeChildWindow(self)
        self.orderOut(nil)
    }
}

@MainActor
final class CommitmentBubbleView: NSView {
    var pointsDown = true { didSet { self.layoutButton(); self.needsDisplay = true } }
    var arrowX: CGFloat = 56 { didSet { self.needsDisplay = true } }
    var onActivate: (() -> Void)?
    private let button = CommitmentNoticeButton()

    var noticeSize: CGSize {
        CGSize(width: max(112, ceil(self.button.intrinsicContentSize.width) + 24), height: 38)
    }

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 112, height: 38))
        self.button.isBordered = false
        self.button.setButtonType(.momentaryChange)
        self.button.target = self
        self.button.action = #selector(self.activate)
        self.addSubview(self.button)
        self.update()
        self.layoutButton()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update() {
        self.button.attributedTitle = NSAttributedString(
            string: L10n.text("新的Tibo重置"),
            attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                         .foregroundColor: NSColor.systemOrange])
    }

    @objc private func activate() { self.onActivate?() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        self.needsDisplay = true
    }

    private func layoutButton() {
        let offset: CGFloat = self.pointsDown ? 6 : 0
        self.button.frame = CGRect(x: 1, y: offset + 1, width: self.bounds.width - 2, height: 30)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let body = CGRect(x: 0.5, y: self.pointsDown ? 6.5 : 0.5, width: self.bounds.width - 1, height: 31)
        let path = NSBezierPath(roundedRect: body, xRadius: 10, yRadius: 10)
        NSColor.windowBackgroundColor.setFill()
        path.fill()
        NSColor.separatorColor.withAlphaComponent(0.5).setStroke()
        path.lineWidth = 1
        path.stroke()

        let baseY = self.pointsDown ? body.minY + 1 : body.maxY - 1
        let tipY: CGFloat = self.pointsDown ? 0.5 : self.bounds.maxY - 0.5
        let arrow = NSBezierPath()
        arrow.move(to: CGPoint(x: self.arrowX - 6, y: baseY))
        arrow.line(to: CGPoint(x: self.arrowX, y: tipY))
        arrow.line(to: CGPoint(x: self.arrowX + 6, y: baseY))
        NSColor.windowBackgroundColor.setFill()
        arrow.fill()
        NSColor.separatorColor.withAlphaComponent(0.5).setStroke()
        arrow.stroke()
    }
}

private final class CommitmentNoticeButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
