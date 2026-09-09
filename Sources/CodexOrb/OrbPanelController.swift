import AppKit
import CodexOrbCore

enum OrbDisplayState: Equatable {
    case empty
    case loading(previous: CodexUsage?)
    case available(CodexUsage)
    case partial(CodexUsage, message: String)
    case failed(previous: CodexUsage?, message: String)

    var usage: CodexUsage? {
        switch self {
        case .empty: nil
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
        static let scale = "CodexOrb.capsuleScale"
        static let centerX = "CodexOrb.windowCenterX"
        static let centerY = "CodexOrb.windowCenterY"
    }

    var onRefresh: (() -> Void)?
    var onSettings: (() -> Void)?
    var onQuit: (() -> Void)?
    var onConsumeReset: ((String?) -> Void)?
    var onDiscardDamagedReset: (() -> Void)?
    var resetBusy = false { didSet { refreshResetContent() } }
    var resetRecoveryAvailable = false { didSet { refreshResetContent() } }
    var resetRecoveryDamaged = false { didSet { refreshResetContent() } }

    private func refreshResetContent() {
        if let popover = resetPopover, detailKind == .resets { configureResetContent(popover) }
    }

    private let panel: OrbPanel
    private let orbView: OrbView
    private let accountBadgePanel: AccountBadgePanel
    private let accountBadgeView: AccountBadgeView
    private let defaults: UserDefaults
    private var capsuleScale: CGFloat
    private var accountInfo: AccountBadgeInfo?
    private var resizeStartFrame: CGRect?
    private var resizeEdge: CapsuleGeometry.Edge = []
    private enum DetailKind { case resets, quota, tokens }
    private var detailKind: DetailKind = .resets
    private var resetPopover: NSPopover?
    private var accountPopover: NSPopover?
    private var confirmationCompletion: ((Bool) -> Void)?
    private var isHoveringCapsule = false
    private var isCapsuleExpanded = false
    private var isExpandedByDefault = false
    private var resizeTask: Task<Void, Never>?
    private var hoverDismissTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.capsuleScale = CapsuleGeometry.scale(CGFloat(defaults.double(forKey: DefaultsKey.scale)))
        self.orbView = OrbView(frame: CGRect(origin: .zero, size: Layout.collapsedSize))
        self.accountBadgeView = AccountBadgeView(frame: CGRect(
            x: 0,
            y: 0,
            width: AccountBadgeLayout.baseSize,
            height: AccountBadgeLayout.baseSize))
        self.accountBadgePanel = AccountBadgePanel(
            contentRect: CGRect(
                x: 0,
                y: 0,
                width: AccountBadgeLayout.baseSize,
                height: AccountBadgeLayout.baseSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        self.panel = OrbPanel(
            contentRect: CGRect(origin: .zero, size: Layout.collapsedSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        super.init()

        self.orbView.delegate = self
        self.configure(self.panel, contentView: self.orbView)
        self.accountBadgeView.onActivate = { [weak self] in self?.showAccountDetails() }
        self.configure(self.accountBadgePanel, contentView: self.accountBadgeView)
        self.accountBadgePanel.hasShadow = false
        self.restorePosition()
        self.accountBadgePanel.orderOut(nil)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(self.screenParametersDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil)
    }

    func reloadLanguage() {
        self.resetPopover?.close()
        self.accountPopover?.close()
        // Reassigning refreshes both the drawing and accessibility description.
        let state = self.orbView.displayState
        self.orbView.displayState = state
        self.accountBadgeView.account = self.accountInfo
        self.accountBadgePanel.invalidateCursorRects(for: self.accountBadgeView)
    }

    func updateDefaultExpansion(_ expanded: Bool, animated: Bool = true) {
        self.isExpandedByDefault = expanded
        self.hoverDismissTask?.cancel()
        guard self.resizeStartFrame == nil else { return }
        self.setCapsuleExpanded(expanded || self.isHoveringCapsule, animated: animated)
    }

    func show() {
        self.panel.orderFrontRegardless()
        self.positionAccountBadge()
    }

    func close() {
        self.resetPopover?.close()
        self.accountPopover?.close()
        self.hoverDismissTask?.cancel()
        self.resizeTask?.cancel()
        NotificationCenter.default.removeObserver(self)
        self.accountBadgePanel.orderOut(nil)
        self.accountBadgePanel.close()
        self.panel.orderOut(nil)
        self.panel.close()
    }

    func updateAccount(_ account: CodexAccount?) {
        let next = account.map { AccountBadgeInfo(email: $0.email, workspace: $0.workspace) }
        guard self.accountInfo != next else {
            self.positionAccountBadge()
            return
        }
        self.accountInfo = next
        self.accountPopover?.close()
        self.accountBadgeView.account = next
        self.accountBadgePanel.invalidateCursorRects(for: self.accountBadgeView)
        self.positionAccountBadge()
    }

    func update(_ state: OrbDisplayState) {
        self.orbView.displayState = state
        if let popover = self.resetPopover, popover.isShown {
            self.configureDetailContent(popover)
        }
    }

    func orbView(_ view: OrbView, didDragBy delta: CGPoint) {
        guard view === self.orbView else { return }
        self.resetPopover?.close()
        var frame = self.panel.frame
        frame.origin.x += delta.x
        frame.origin.y += delta.y
        self.panel.setFrameOrigin(frame.origin)
        self.positionAccountBadge()
    }

    func orbViewDidFinishDragging(_ view: OrbView) {
        guard view === self.orbView else { return }
        self.constrainToVisibleScreen()
        self.persistCenter()
    }

    func orbView(_ view: OrbView, didBeginResizing edge: CapsuleGeometry.Edge) {
        guard view === self.orbView else { return }
        self.resizeTask?.cancel()
        self.hoverDismissTask?.cancel()
        // Preserve an in-flight hover animation's geometry while the user holds the edge.
        self.resizeStartFrame = self.panel.frame
        self.resizeEdge = edge
        self.resetPopover?.close()
        self.accountPopover?.close()
    }

    func orbView(_ view: OrbView, didResizeBy delta: CGPoint) {
        guard view === self.orbView, let start = self.resizeStartFrame else { return }
        let visible = self.panel.screen?.frame ?? start
        let baseWidth = self.isCapsuleExpanded ? Layout.expandedSize.width : Layout.collapsedSize.width
        let limit = min(CapsuleGeometry.maximumScale,
                        (visible.width - 2 * Layout.edgeInset) / baseWidth,
                        (visible.height - 2 * Layout.edgeInset) / Layout.expandedSize.height)
        let frame = CapsuleGeometry.resizedFrame(start: start, delta: delta, edge: self.resizeEdge,
                                                expanded: self.isCapsuleExpanded, maximumScale: limit,
                                                logicalWidth: start.width / (start.height / Layout.expandedSize.height))
        self.capsuleScale = frame.height / Layout.expandedSize.height
        self.applyFrame(self.constrainedFrame(frame), display: true)
    }

    func orbViewDidFinishResizing(_ view: OrbView) {
        guard view === self.orbView else { return }
        self.resizeStartFrame = nil
        self.resizeEdge = []
        self.defaults.set(Double(self.capsuleScale), forKey: DefaultsKey.scale)
        self.persistCenter()
        self.setCapsuleExpanded(self.isCapsuleExpanded, force: true)
        // Resume hover behavior on the next movement; do not expand beneath a released edge.
        if !self.panel.frame.contains(NSEvent.mouseLocation) {
            self.orbView(view, didChangeHover: false)
        }
    }

    func orbView(_ view: OrbView, didChangeHover isHovering: Bool) {
        guard view === self.orbView else { return }
        self.isHoveringCapsule = isHovering
        guard self.resizeStartFrame == nil else { return }
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

    func orbViewDidRequestQuotaDetails(_ view: OrbView) {
        self.showDetails(.quota, from: view)
    }

    func orbViewDidRequestTokenDetails(_ view: OrbView) {
        self.showDetails(.tokens, from: view)
    }

    func orbViewDidRequestResetCards(_ view: OrbView) {
        self.showDetails(.resets, from: view)
    }

    private func showDetails(_ kind: DetailKind, from view: OrbView) {
        guard view === self.orbView else { return }
        if let popover = self.resetPopover, popover.isShown {
            let sameKind = self.detailKind == kind
            popover.close()
            if sameKind { return }
        }
        self.detailKind = kind
        self.hoverDismissTask?.cancel()
        self.resizeTask?.cancel()
        self.isCapsuleExpanded = true
        var frame = self.panel.frame
        frame.origin.x = frame.maxX - Layout.expandedSize.width * self.capsuleScale
        frame.size.width = Layout.expandedSize.width * self.capsuleScale
        self.applyFrame(self.constrainedFrame(frame), display: true)
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        self.configureDetailContent(popover)
        self.resetPopover = popover
        let anchorRect: CGRect
        switch kind {
        case .quota: anchorRect = view.quotaDetailsRect
        case .tokens: anchorRect = view.tokenDetailsRect
        case .resets: anchorRect = view.resetCardsRect
        }
        let anchor = self.panel.convertToScreen(view.convert(anchorRect, to: nil))
        let visible = self.panel.screen?.visibleFrame ?? self.panel.frame
        let edge = Self.resetPopoverEdge(anchor: anchor, visibleFrame: visible, contentHeight: popover.contentSize.height)
        popover.show(relativeTo: anchorRect, of: view, preferredEdge: edge)
        popover.contentViewController?.view.window?.makeKey()
        if let content = popover.contentViewController?.view {
            content.window?.makeFirstResponder(content)
        }
    }

    private func showAccountDetails() {
        guard let accountInfo else { return }
        self.resetPopover?.close()
        self.accountPopover?.close()

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        let content = AccountDetailsView(account: accountInfo)
        let controller = NSViewController()
        controller.view = content
        popover.contentViewController = controller
        popover.contentSize = content.frame.size
        self.accountPopover = popover

        let screen = self.panel.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? self.panel.frame
        let placement = AccountBadgeLayout.frame(
            capsuleFrame: self.panel.frame,
            visibleFrame: visible,
            scale: self.capsuleScale)
        let edge = Self.resetPopoverEdge(
            anchor: placement.frame,
            visibleFrame: visible,
            contentHeight: popover.contentSize.height)
        popover.show(
            relativeTo: self.accountBadgeView.bounds,
            of: self.accountBadgeView,
            preferredEdge: edge)
        popover.contentViewController?.view.window?.makeKey()
    }

    static func resetPopoverEdge(anchor: NSRect, visibleFrame: NSRect, contentHeight: CGFloat) -> NSRectEdge {
        let below = max(0, anchor.minY - visibleFrame.minY)
        let above = max(0, visibleFrame.maxY - anchor.maxY)
        let requiredHeight = contentHeight + 24 // Arrow and window margins.
        return below >= requiredHeight || below >= above ? .minY : .maxY
    }

    private func configureDetailContent(_ popover: NSPopover) {
        guard confirmationCompletion == nil else { return }
        guard self.detailKind == .quota else {
            if self.detailKind == .tokens {
                self.configureTokenContent(popover)
                return
            }
            self.configureResetContent(popover)
            return
        }
        if let content = popover.contentViewController?.view as? QuotaDetailsView {
            content.update(self.orbView.displayState.usage)
            return
        }
        let content = QuotaDetailsView(usage: self.orbView.displayState.usage)
        content.onClose = { [weak popover] in popover?.performClose(nil) }
        let controller = NSViewController()
        controller.view = content
        popover.contentViewController = controller
        popover.contentSize = content.frame.size
    }

    private func configureTokenContent(_ popover: NSPopover) {
        if let content = popover.contentViewController?.view as? TokenDetailsView {
            content.update(self.orbView.displayState.usage)
            popover.contentSize = content.frame.size
            return
        }
        let content = TokenDetailsView(usage: self.orbView.displayState.usage)
        content.onClose = { [weak popover] in popover?.performClose(nil) }
        let controller = NSViewController()
        controller.view = content
        popover.contentViewController = controller
        popover.contentSize = content.frame.size
    }

    private func configureResetContent(_ popover: NSPopover) {
        guard confirmationCompletion == nil else { return }
        let cards = ResetCardsView(credits: self.orbView.displayState.usage?.resetCredits,
                                  busy: resetBusy, recovery: resetRecoveryAvailable,
                                  damagedRecovery: resetRecoveryDamaged,
                                  onRecover: { [weak self] in self?.onConsumeReset?(nil) },
                                  onDiscardDamaged: { [weak self] in self?.onDiscardDamagedReset?() },
                                  onConsume: { [weak self] id in self?.onConsumeReset?(id) })
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
        if let closed = notification.object as? NSPopover, closed === self.accountPopover {
            self.accountPopover = nil
            return
        }
        guard let closed = notification.object as? NSPopover, closed === self.resetPopover else { return }
        self.resetPopover = nil
        let completion = confirmationCompletion
        confirmationCompletion = nil
        completion?(false)
        let hovering = self.panel.frame.contains(NSEvent.mouseLocation)
        self.orbView(self.orbView, didChangeHover: hovering)
    }

    func confirmReset(account: String, recovering: Bool) async -> Bool {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(returning: false); return }
                resetPopover?.close()
                hoverDismissTask?.cancel()
                let popover = NSPopover()
                popover.behavior = .transient
                popover.animates = false
                popover.delegate = self
                let content = ResetConfirmation(account: account, recovering: recovering) { [weak self] confirmed in
                    self?.finishResetConfirmation(confirmed)
                }
                let controller = NSViewController()
                controller.view = content
                popover.contentViewController = controller
                popover.contentSize = content.frame.size
                detailKind = .resets
                confirmationCompletion = { continuation.resume(returning: $0) }
                resetPopover = popover
                let rect = orbView.resetCardsRect
                let anchor = panel.convertToScreen(orbView.convert(rect, to: nil))
                let edge = Self.resetPopoverEdge(anchor: anchor, visibleFrame: panel.screen?.visibleFrame ?? panel.frame,
                                                contentHeight: content.frame.height)
                popover.show(relativeTo: rect, of: orbView, preferredEdge: edge)
                content.window?.makeKey()
                content.window?.makeFirstResponder(content)
                if !popover.isShown { finishResetConfirmation(false) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finishResetConfirmation(false) }
        }
    }

    private func finishResetConfirmation(_ confirmed: Bool) {
        let completion = confirmationCompletion
        confirmationCompletion = nil
        resetPopover?.close()
        completion?(confirmed)
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
        panel.acceptsMouseMovedEvents = true
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.allowsToolTipsWhenApplicationIsInactive = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.isExcludedFromWindowsMenu = true
    }

    private func configure(_ panel: AccountBadgePanel, contentView: AccountBadgeView) {
        panel.contentView = contentView
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.acceptsMouseMovedEvents = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isExcludedFromWindowsMenu = true
    }

    private func setCapsuleExpanded(_ expanded: Bool, animated: Bool = true, force: Bool = false) {
        guard force || self.isCapsuleExpanded != expanded else { return }
        self.isCapsuleExpanded = expanded
        self.resizeTask?.cancel()
        let startWidth = self.panel.frame.width
        let targetWidth = (expanded ? Layout.expandedSize.width : Layout.collapsedSize.width) * self.capsuleScale
        if !animated {
            var frame = self.panel.frame
            let right = frame.maxX
            frame.size.width = targetWidth
            frame.origin.x = right - frame.width
            self.applyFrame(self.constrainedFrame(frame), display: true)
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
                self.applyFrame(self.constrainedFrame(frame), display: true)
                self.orbView.needsDisplay = true
                if progress >= 1 { return }
                do { try await Task.sleep(nanoseconds: 16_666_667) }
                catch { return }
            }
        }
    }

    private func restorePosition() {
        let defaults = self.defaults
        let storedX = defaults.object(forKey: DefaultsKey.centerX) as? Double
        let storedY = defaults.object(forKey: DefaultsKey.centerY) as? Double
        let fallbackScreen = NSScreen.main ?? NSScreen.screens.first
        let fallbackCenter = CGPoint(
            x: (fallbackScreen?.frame.maxX ?? 900) - 54,
            y: fallbackScreen?.frame.midY ?? 450)
        let center = CGPoint(x: storedX ?? fallbackCenter.x, y: storedY ?? fallbackCenter.y)
        let frame = CGRect(
            x: center.x - Layout.collapsedSize.width * self.capsuleScale / 2,
            y: center.y - Layout.collapsedSize.height * self.capsuleScale / 2,
            width: Layout.collapsedSize.width * self.capsuleScale,
            height: Layout.collapsedSize.height * self.capsuleScale)
        self.applyFrame(self.constrainedFrame(frame), display: false)
    }

    private func applyFrame(_ frame: CGRect, display: Bool) {
        self.panel.setFrame(frame, display: false)
        self.orbView.bounds = CGRect(x: 0, y: 0, width: frame.width / self.capsuleScale,
                                    height: frame.height / self.capsuleScale)
        self.positionAccountBadge()
        self.orbView.needsDisplay = true
        self.panel.invalidateCursorRects(for: self.orbView)
        if display { self.panel.displayIfNeeded() }
    }

    private func positionAccountBadge() {
        guard self.accountInfo != nil else {
            self.accountBadgePanel.orderOut(nil)
            return
        }
        let screen = self.panel.screen
            ?? NSScreen.screens.first(where: { $0.frame.intersects(self.panel.frame) })
            ?? NSScreen.main
        guard let screen else { return }
        let placement = AccountBadgeLayout.frame(
            capsuleFrame: self.panel.frame,
            visibleFrame: screen.visibleFrame,
            scale: self.capsuleScale)
        self.accountBadgePanel.setFrame(placement.frame, display: true)
        if self.panel.isVisible { self.accountBadgePanel.orderFrontRegardless() }
    }

    private func persistCenter() {
        let frame = self.panel.frame
        self.defaults.set(Double(frame.maxX - Layout.collapsedSize.width * self.capsuleScale / 2), forKey: DefaultsKey.centerX)
        self.defaults.set(Double(frame.midY), forKey: DefaultsKey.centerY)
    }

    private func constrainToVisibleScreen() {
        let originalFrame = self.panel.frame
        let constrainedFrame = self.constrainedFrame(originalFrame)
        self.applyFrame(constrainedFrame, display: true)
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
