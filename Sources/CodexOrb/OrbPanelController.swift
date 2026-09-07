import AppKit
import CodexOrbCore

enum OrbDisplayState: Equatable {
    case loading(previous: CodexUsage?)
    case available(CodexUsage)
    case partial(CodexUsage, message: String)
    case failed(previous: CodexUsage?, message: String)

    var usage: CodexUsage? {
        switch self {
        case let .loading(previous), let .failed(previous, _): previous
        case let .available(usage), let .partial(usage, _): usage
        }
    }
}

@MainActor
final class OrbPanelController: NSObject, OrbViewDelegate, NSPopoverDelegate {
    private enum Layout {
        static let collapsedSize = CGSize(width: 60, height: 56)
        static let expandedSize = CGSize(width: 176, height: 56)
        static let edgeInset: CGFloat = 10
        static let hoverDismissDelayNanoseconds: UInt64 = 180_000_000
    }

    private enum DefaultsKey {
        static let centerX = "CodexOrb.windowCenterX"
        static let centerY = "CodexOrb.windowCenterY"
    }

    var onRefresh: (() -> Void)?
    var onSettings: (() -> Void)?
    var onQuit: (() -> Void)?

    private let panel: OrbPanel
    private let orbView: OrbView
    private var resetPopover: NSPopover?
    private var isHoveringCapsule = false
    private var isCapsuleExpanded = false
    private var isExpandedByDefault = false
    private var resizeTask: Task<Void, Never>?
    private var hoverDismissTask: Task<Void, Never>?

    override init() {
        self.orbView = OrbView(frame: CGRect(origin: .zero, size: Layout.collapsedSize))
        self.panel = OrbPanel(
            contentRect: CGRect(origin: .zero, size: Layout.collapsedSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        super.init()

        self.orbView.delegate = self
        self.configure(self.panel, contentView: self.orbView)
        self.restorePosition()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(self.screenParametersDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil)
    }

    func updateDailyQuota(_ daily: DailyQuotaUsage?, enabled: Bool) {
        for view in [self.orbView] {
            view.dailyQuotaEnabled = enabled
            view.dailyQuota = daily
        }
    }

    func updateDefaultExpansion(_ expanded: Bool, animated: Bool = true) {
        self.isExpandedByDefault = expanded
        self.hoverDismissTask?.cancel()
        self.setCapsuleExpanded(expanded || self.isHoveringCapsule, animated: animated)
    }

    func show() {
        self.panel.orderFrontRegardless()
    }

    func close() {
        self.resetPopover?.close()
        self.hoverDismissTask?.cancel()
        self.resizeTask?.cancel()
        NotificationCenter.default.removeObserver(self)
        self.panel.orderOut(nil)
        self.panel.close()
    }

    func update(_ state: OrbDisplayState) {
        self.orbView.displayState = state
        if let popover = self.resetPopover, popover.isShown {
            self.configureResetContent(popover)
        }
    }

    func orbView(_ view: OrbView, didDragBy delta: CGPoint) {
        guard view === self.orbView else { return }
        self.resetPopover?.close()
        var frame = self.panel.frame
        frame.origin.x += delta.x
        frame.origin.y += delta.y
        self.panel.setFrameOrigin(frame.origin)
    }

    func orbViewDidFinishDragging(_ view: OrbView) {
        guard view === self.orbView else { return }
        self.constrainToVisibleScreen()
        self.persistCenter()
    }

    func orbView(_ view: OrbView, didChangeHover isHovering: Bool) {
        guard view === self.orbView else { return }
        self.isHoveringCapsule = isHovering
        self.hoverDismissTask?.cancel()
        guard self.resetPopover?.isShown != true else { return }
        if isHovering {
            self.setCapsuleExpanded(true)
        } else {
            self.hoverDismissTask = Task { @MainActor [weak self] in
                do { try await Task.sleep(nanoseconds: Layout.hoverDismissDelayNanoseconds) }
                catch { return }
                guard let self, !self.isHoveringCapsule else { return }
                self.setCapsuleExpanded(self.isExpandedByDefault)
            }
        }
    }

    func orbViewDidRequestResetCards(_ view: OrbView) {
        guard view === self.orbView else { return }
        if let popover = self.resetPopover, popover.isShown {
            popover.performClose(nil)
            return
        }
        self.hoverDismissTask?.cancel()
        self.resizeTask?.cancel()
        var frame = self.panel.frame
        frame.origin.x = frame.maxX - Layout.expandedSize.width
        frame.size.width = Layout.expandedSize.width
        self.panel.setFrame(self.constrainedFrame(frame), display: true)
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        self.configureResetContent(popover)
        self.resetPopover = popover
        let anchor = self.panel.convertToScreen(view.convert(view.resetCardsRect, to: nil))
        let visible = self.panel.screen?.visibleFrame ?? self.panel.frame
        let edge = Self.resetPopoverEdge(anchor: anchor, visibleFrame: visible, contentHeight: popover.contentSize.height)
        popover.show(relativeTo: view.resetCardsRect, of: view, preferredEdge: edge)
        popover.contentViewController?.view.window?.makeKey()
        if let content = popover.contentViewController?.view {
            content.window?.makeFirstResponder(content)
        }
    }

    static func resetPopoverEdge(anchor: NSRect, visibleFrame: NSRect, contentHeight: CGFloat) -> NSRectEdge {
        let below = max(0, anchor.minY - visibleFrame.minY)
        let above = max(0, visibleFrame.maxY - anchor.maxY)
        let requiredHeight = contentHeight + 24 // Arrow and window margins.
        return below >= requiredHeight || below >= above ? .minY : .maxY
    }

    private func configureResetContent(_ popover: NSPopover) {
        let cards = ResetCardsView(credits: self.orbView.displayState.usage?.resetCredits)
        let scroll = ResetCardsScrollView(frame: NSRect(x: 0, y: 0, width: min(360, cards.frame.width), height: cards.frame.height))
        scroll.onClose = { [weak popover] in popover?.performClose(nil) }
        scroll.borderType = .noBorder
        scroll.scrollerStyle = .overlay
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = cards.frame.width > scroll.frame.width
        scroll.hasVerticalScroller = false
        scroll.documentView = cards
        let controller = NSViewController()
        controller.view = scroll
        popover.contentViewController = controller
        popover.contentSize = scroll.frame.size
    }

    func popoverDidClose(_ notification: Notification) {
        self.resetPopover = nil
        let hovering = self.panel.frame.contains(NSEvent.mouseLocation)
        self.orbView(self.orbView, didChangeHover: hovering)
    }

    func orbViewDidRequestRefresh(_ view: OrbView) {
        _ = view
        self.onRefresh?()
    }

    func orbViewDidRequestSettings(_ view: OrbView) {
        _ = view
        self.onSettings?()
    }

    func orbViewDidRequestQuit(_ view: OrbView) {
        _ = view
        self.onQuit?()
    }

    @objc private func screenParametersDidChange() {
        self.constrainToVisibleScreen()
        self.persistCenter()
    }

    private func configure(_ panel: OrbPanel, contentView: OrbView) {
        panel.contentView = contentView
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.allowsToolTipsWhenApplicationIsInactive = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.isExcludedFromWindowsMenu = true
    }

    private func setCapsuleExpanded(_ expanded: Bool, animated: Bool = true) {
        guard self.isCapsuleExpanded != expanded else { return }
        self.isCapsuleExpanded = expanded
        self.resizeTask?.cancel()
        let startWidth = self.panel.frame.width
        let targetWidth = expanded ? Layout.expandedSize.width : Layout.collapsedSize.width
        if !animated {
            var frame = self.panel.frame
            let right = frame.maxX
            frame.size.width = targetWidth
            frame.origin.x = right - frame.width
            self.panel.setFrame(self.constrainedFrame(frame), display: true)
            self.orbView.needsDisplay = true
            return
        }
        self.resizeTask = Task { @MainActor [weak self] in
            let start = ProcessInfo.processInfo.systemUptime
            while !Task.isCancelled {
                guard let self else { return }
                let progress = min(1, (ProcessInfo.processInfo.systemUptime - start) / 0.28)
                let eased = progress * progress * (3 - 2 * progress)
                var frame = self.panel.frame
                let right = frame.maxX
                frame.size.width = startWidth + (targetWidth - startWidth) * eased
                frame.origin.x = right - frame.width
                self.panel.setFrame(self.constrainedFrame(frame), display: true)
                self.orbView.needsDisplay = true
                if progress >= 1 { return }
                do { try await Task.sleep(nanoseconds: 16_666_667) }
                catch { return }
            }
        }
    }

    private func restorePosition() {
        let defaults = UserDefaults.standard
        let storedX = defaults.object(forKey: DefaultsKey.centerX) as? Double
        let storedY = defaults.object(forKey: DefaultsKey.centerY) as? Double
        let fallbackScreen = NSScreen.main ?? NSScreen.screens.first
        let fallbackCenter = CGPoint(
            x: (fallbackScreen?.frame.maxX ?? 900) - 54,
            y: fallbackScreen?.frame.midY ?? 450)
        let center = CGPoint(x: storedX ?? fallbackCenter.x, y: storedY ?? fallbackCenter.y)
        let frame = CGRect(
            x: center.x - Layout.collapsedSize.width / 2,
            y: center.y - Layout.collapsedSize.height / 2,
            width: Layout.collapsedSize.width,
            height: Layout.collapsedSize.height)
        self.panel.setFrame(self.constrainedFrame(frame), display: false)
    }

    private func persistCenter() {
        let frame = self.panel.frame
        UserDefaults.standard.set(Double(frame.maxX - Layout.collapsedSize.width / 2), forKey: DefaultsKey.centerX)
        UserDefaults.standard.set(Double(frame.midY), forKey: DefaultsKey.centerY)
    }

    private func constrainToVisibleScreen() {
        let originalFrame = self.panel.frame
        let constrainedFrame = self.constrainedFrame(originalFrame)
        self.panel.setFrame(constrainedFrame, display: true)
    }

    private func constrainedFrame(_ frame: CGRect) -> CGRect {
        let center = CGPoint(x: frame.midX, y: frame.midY)
        let screen = NSScreen.screens.first(where: { $0.frame.contains(center) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen else { return frame }

        let bounds = CGRect(
            x: screen.frame.minX + Layout.edgeInset,
            y: screen.frame.minY,
            width: screen.frame.width - 2 * Layout.edgeInset,
            height: screen.frame.height - Layout.edgeInset)
        var result = frame
        result.origin.x = min(max(result.origin.x, bounds.minX), bounds.maxX - result.width)
        result.origin.y = min(max(result.origin.y, bounds.minY), bounds.maxY - result.height)
        return result
    }
}

private final class OrbPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
