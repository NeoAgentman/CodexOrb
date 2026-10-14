import AppKit
import CodexOrbCore

/// An independent badge, so service incidents do not replace quota or local-error indicators.
@MainActor
final class ServiceStatusPanel: NSPanel, NSPopoverDelegate {
    private let badge = ServiceStatusButton(frame: NSRect(x: 0, y: 0, width: 26, height: 26))
    private(set) var state = OpenAIServiceStatusState()
    private var popover: NSPopover?
    var onOpen: (() -> Void)?
    var onCloseDetails: (() -> Void)?
    var isShowingDetails: Bool { popover?.isShown == true }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init() {
        super.init(contentRect: badge.frame, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        contentView = badge
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        allowsToolTipsWhenApplicationIsInactive = true
        badge.isBordered = false
        badge.imagePosition = .imageOnly
        badge.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
        badge.target = self
        badge.action = #selector(showDetails)
    }

    func update(_ state: OpenAIServiceStatusState, beside anchor: NSWindow, avoiding: [NSRect] = []) {
        self.state = state
        guard state.snapshot?.hasIssues == true else {
            dismissDetails()
            parent?.removeChildWindow(self)
            orderOut(nil)
            return
        }
        appearance = anchor.effectiveAppearance
        badge.contentTintColor = state.snapshot?.isSevere == true ? .systemRed : .systemOrange
        let title = L10n.text("OpenAI 服务异常")
        let stale = state.isStale() ? " · " + L10n.text("信息未更新") : ""
        badge.toolTip = title + stale + "\n" + (state.snapshot?.activeIncidents.first?.name ?? state.snapshot?.status.description ?? "")
        badge.setAccessibilityLabel(title + stale)
        if parent !== anchor { anchor.addChildWindow(self, ordered: .above) }
        reposition(beside: anchor, avoiding: avoiding)
        if anchor.isVisible { orderFrontRegardless() }
        if let popover, popover.isShown { configure(popover) }
    }

    func reposition(beside anchor: NSWindow, avoiding: [NSRect] = []) {
        guard state.snapshot?.hasIssues == true else { return }
        let visible = (anchor.screen ?? NSScreen.main)?.visibleFrame ?? anchor.frame
        setFrame(Self.badgeFrame(anchor: anchor.frame, visible: visible, avoiding: avoiding), display: true)
    }

    static func badgeFrame(anchor: NSRect, visible: NSRect, avoiding: [NSRect]) -> NSRect {
        let bounds = visible.insetBy(dx: 4, dy: 4)
        let size: CGFloat = 26
        // Prefer below the right end; the transient reset notice normally sits above.
        let candidates = [
            NSPoint(x: anchor.maxX - size, y: anchor.minY - size - 4),
            NSPoint(x: anchor.minX, y: anchor.minY - size - 4),
            NSPoint(x: anchor.maxX - size, y: anchor.maxY + 4),
            NSPoint(x: anchor.minX, y: anchor.maxY + 4),
            NSPoint(x: anchor.maxX + 4, y: anchor.midY - size / 2),
            NSPoint(x: anchor.minX - size - 4, y: anchor.midY - size / 2),
            NSPoint(x: anchor.maxX - size, y: max(anchor.maxY, avoiding.map(\.maxY).max() ?? anchor.maxY) + 4),
            NSPoint(x: anchor.maxX - size, y: min(anchor.minY, avoiding.map(\.minY).min() ?? anchor.minY) - size - 4),
        ].map { NSRect(origin: $0, size: NSSize(width: size, height: size)) }
        if let frame = candidates.first(where: { bounds.contains($0) && !([anchor] + avoiding).contains(where: $0.intersects) }) {
            return frame
        }
        var fallback = candidates[0]
        fallback.origin.x = min(max(fallback.minX, bounds.minX), bounds.maxX - size)
        fallback.origin.y = min(max(fallback.minY, bounds.minY), bounds.maxY - size)
        return fallback
    }

    @objc func showDetails() {
        guard state.snapshot?.hasIssues == true else { return }
        if popover?.isShown == true { dismissDetails(); return }
        onOpen?()
        let next = NSPopover()
        next.behavior = .transient
        next.animates = false
        next.delegate = self
        next.appearance = effectiveAppearance
        configure(next)
        popover = next
        let visible = screen?.visibleFrame ?? frame
        let edge: NSRectEdge = frame.minY - visible.minY >= next.contentSize.height + 24 ? .minY : .maxY
        next.show(relativeTo: badge.bounds, of: badge, preferredEdge: edge)
        next.contentViewController?.view.window?.makeKey()
    }

    private func configure(_ popover: NSPopover) {
        let content = ServiceStatusDetailsView(state: state)
        let controller = NSViewController()
        controller.view = content
        popover.contentViewController = controller
        popover.contentSize = content.frame.size
        popover.appearance = effectiveAppearance
    }

    func dismissDetails() { popover?.close(); popover = nil }
    func popoverDidClose(_ notification: Notification) { onCloseDetails?() }
    func reloadAppearance() { popover?.appearance = effectiveAppearance; badge.needsDisplay = true }
}

private final class ServiceStatusButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1)).fill()
        super.draw(dirtyRect)
    }
}

@MainActor
final class ServiceStatusDetailsView: NSScrollView {
    private var links: [URL] = []

    init(state: OpenAIServiceStatusState) {
        super.init(frame: NSRect(x: 0, y: 0, width: 360, height: 200))
        drawsBackground = true
        backgroundColor = .windowBackgroundColor
        borderType = .noBorder
        hasVerticalScroller = true
        scrollerStyle = .overlay
        let document = ServiceStatusDocumentView(frame: NSRect(x: 0, y: 0, width: 360, height: 200))
        documentView = document
        var y: CGFloat = 16
        func label(_ text: String, size: CGFloat = 12, bold: Bool = false, color: NSColor = .labelColor) {
            let field = NSTextField(wrappingLabelWithString: text)
            field.font = .systemFont(ofSize: size, weight: bold ? .semibold : .regular)
            field.textColor = color
            field.isSelectable = true
            let width: CGFloat = 324
            let height = max(size + 5, ceil(field.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: 100_000)).height))
            field.frame = NSRect(x: 18, y: y, width: width, height: height)
            document.addSubview(field)
            y += height + 8
        }
        func link(_ title: String, url: URL) {
            let button = NSButton(title: title, target: self, action: #selector(openLink(_:)))
            button.bezelStyle = .rounded
            button.tag = links.count
            links.append(url)
            button.frame = NSRect(x: 18, y: y, width: 150, height: 28)
            document.addSubview(button)
            y += 38
        }
        label(L10n.text("OpenAI 服务异常"), size: 15, bold: true)
        if state.isStale() { label(L10n.text("信息未更新，以下为上次查询结果"), color: .systemOrange) }
        if let checked = state.checkedAt {
            label(L10n.text("最近检查：\(checked.formatted(Date.FormatStyle(date: .omitted, time: .standard).locale(AppLanguage.load().locale)))"),
                  size: 11, color: .secondaryLabelColor)
        }
        if let snapshot = state.snapshot {
            if !snapshot.affectedComponents.isEmpty {
                label(L10n.text("受影响服务：\(snapshot.affectedComponents.map(\.name).joined(separator: "、"))"), color: .secondaryLabelColor)
            }
            if snapshot.activeIncidents.isEmpty { label(snapshot.status.description) }
            for incident in snapshot.activeIncidents {
                y += 6
                label(incident.name, size: 13, bold: true)
                label(Self.stage(incident.status), color: snapshot.isSevere ? .systemRed : .systemOrange)
                label(incident.latestUpdate?.body ?? L10n.text("暂无详细进展"))
                let rawDate = incident.latestUpdate?.created_at ?? incident.updated_at
                label(L10n.text("更新时间：\(Self.dateText(rawDate))"), size: 11, color: .secondaryLabelColor)
                link(L10n.text("查看故障详情"), url: incident.url)
            }
        }
        link(L10n.text("查看状态官网"), url: OpenAIServiceStatusSource.website)
        document.frame.size.height = y + 8
        frame.size.height = min(420, y + 8)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func openLink(_ sender: NSButton) {
        guard links.indices.contains(sender.tag) else { return }
        NSWorkspace.shared.open(links[sender.tag])
    }

    private static func stage(_ value: String) -> String {
        switch value {
        case "investigating": L10n.text("正在调查")
        case "identified": L10n.text("已定位问题")
        case "monitoring": L10n.text("恢复观察中")
        case "in_progress": L10n.text("维护进行中")
        case "verifying": L10n.text("正在验证")
        default: value
        }
    }

    private static func dateText(_ value: String) -> String {
        let formatter = ISO8601DateFormatter()
        var date = formatter.date(from: value)
        if date == nil {
            formatter.formatOptions.insert(.withFractionalSeconds)
            date = formatter.date(from: value)
        }
        return date?.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(AppLanguage.load().locale)) ?? value
    }
}

private final class ServiceStatusDocumentView: NSView {
    override var isFlipped: Bool { true }
}
