import AppKit
import CodexOrbCore

@MainActor
protocol OrbViewDelegate: AnyObject {
    func orbView(_ view: OrbView, didDragBy delta: CGPoint)
    func orbView(_ view: OrbView, didBeginResizing edge: CapsuleGeometry.Edge)
    func orbView(_ view: OrbView, didResizeBy delta: CGPoint)
    func orbViewDidFinishResizing(_ view: OrbView)
    func orbViewDidFinishDragging(_ view: OrbView)
    func orbView(_ view: OrbView, didChangeHover isHovering: Bool)
    func orbViewDidRequestQuotaDetails(_ view: OrbView)
    func orbViewDidRequestTokenDetails(_ view: OrbView)
    func orbViewDidRequestResetCards(_ view: OrbView)
    func orbViewDidRequestRefresh(_ view: OrbView)
    func orbViewDidRequestSettings(_ view: OrbView)
    func orbViewDidRequestQuit(_ view: OrbView)
}

@MainActor
final class OrbView: NSView, NSMenuDelegate {
    private static let minimumExpandedHitWidth: CGFloat = 164

    weak var delegate: OrbViewDelegate?

    var displayState: OrbDisplayState = .loading(previous: nil) {
        didSet {
            self.updateSummaryToolTip()
            self.updateAccessibility()
            self.needsDisplay = true
        }
    }

    private var hoveredResizeEdge: CapsuleGeometry.Edge = []
    private var isResizing = false
    private var resizeStartLocation: CGPoint?
    private var pressedQuotaDetails = false
    private var pressedTokenDetails = false
    private var pressedResetCards = false
    private var lastDragLocation: CGPoint?
    private var totalDragDistance: CGFloat = 0
    private var trackingArea: NSTrackingArea?
    override var isFlipped: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        self.autoresizingMask = [.width, .height]
        self.wantsLayer = true
        self.layer?.masksToBounds = false
        self.toolTip = nil
        self.setAccessibilityElement(true)
        self.setAccessibilityRole(.button)
        self.updateAccessibility()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        self.drawCollapsed(in: context)
        if !self.hoveredResizeEdge.isEmpty {
            let rect = self.bounds.insetBy(dx: 3, dy: 3)
            let outline = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
            outline.lineWidth = 1 / max(1, self.frame.height / 56)
            NSColor.controlAccentColor.withAlphaComponent(0.7).setStroke()
            outline.stroke()
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            self.removeTrackingArea(trackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: self.bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .cursorUpdate, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil)
        self.addTrackingArea(trackingArea)
        self.trackingArea = trackingArea
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseEntered(with event: NSEvent) {
        _ = event
        self.mouseMoved(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        _ = event
        if !self.isResizing { self.updateResizeCursor([]) }
        self.delegate?.orbView(self, didChangeHover: false)
    }

    private func resizeEdge(at point: CGPoint) -> CapsuleGeometry.Edge {
        CapsuleGeometry.resizeEdge(at: point, bounds: self.bounds, scale: self.frame.height / 56)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        let step = 4 / max(1, self.frame.height / 56)
        for x in stride(from: self.bounds.minX, to: self.bounds.maxX, by: step) {
            for y in stride(from: self.bounds.minY, to: self.bounds.maxY, by: step) {
                let rect = CGRect(x: x, y: y, width: step, height: step).intersection(self.bounds)
                let edge = self.resizeEdge(at: CGPoint(x: rect.midX, y: rect.midY))
                if !edge.isEmpty { self.addCursorRect(rect, cursor: self.resizeCursor(edge)) }
            }
        }
    }

    override func mouseMoved(with event: NSEvent) {
        guard !self.isResizing else { return }
        let edge = self.resizeEdge(at: self.convert(event.locationInWindow, from: nil))
        self.updateResizeCursor(edge)
        if edge.isEmpty { self.delegate?.orbView(self, didChangeHover: true) }
    }

    override func cursorUpdate(with event: NSEvent) {
        self.updateResizeCursor(self.resizeEdge(at: self.convert(event.locationInWindow, from: nil)))
    }

    private func resizeCursor(_ edge: CapsuleGeometry.Edge) -> NSCursor {
        if edge.contains(.left) || edge.contains(.right) { return .resizeLeftRight }
        return edge.isEmpty ? .arrow : .resizeUpDown
    }

    private func updateResizeCursor(_ edge: CapsuleGeometry.Edge) {
        if self.hoveredResizeEdge != edge {
            self.hoveredResizeEdge = edge
            self.needsDisplay = true
        }
        self.resizeCursor(edge).set()
    }

    private func screenLocation(of event: NSEvent) -> CGPoint {
        self.window?.convertPoint(toScreen: event.locationInWindow) ?? event.locationInWindow
    }

    override func mouseDown(with event: NSEvent) {
        let edge = self.resizeEdge(at: self.convert(event.locationInWindow, from: nil))
        if !edge.isEmpty {
            self.updateResizeCursor(edge)
            self.isResizing = true
            self.resizeStartLocation = self.screenLocation(of: event)
            self.delegate?.orbView(self, didBeginResizing: edge)
            return
        }
        let location = self.convert(event.locationInWindow, from: nil)
        self.pressedQuotaDetails = self.quotaDetailsRect.contains(location)
        self.pressedTokenDetails = self.tokenConsumptionContains(location)
        self.pressedResetCards = self.resetCardsRect.contains(location)
            && self.bounds.width >= Self.minimumExpandedHitWidth
        self.lastDragLocation = self.screenLocation(of: event)
        self.totalDragDistance = 0
    }

    override func mouseDragged(with event: NSEvent) {
        _ = event
        if self.isResizing, let start = self.resizeStartLocation {
            let current = self.screenLocation(of: event)
            self.delegate?.orbView(self, didResizeBy: CGPoint(x: current.x - start.x, y: current.y - start.y))
            return
        }
        guard let previous = self.lastDragLocation else { return }
        let current = self.screenLocation(of: event)
        let delta = CGPoint(x: current.x - previous.x, y: current.y - previous.y)
        self.totalDragDistance += hypot(delta.x, delta.y)
        self.lastDragLocation = current
        self.delegate?.orbView(self, didDragBy: delta)
    }

    override func mouseUp(with event: NSEvent) {
        if self.isResizing {
            self.isResizing = false
            self.resizeStartLocation = nil
            self.delegate?.orbViewDidFinishResizing(self)
            self.updateResizeCursor(self.resizeEdge(at: self.convert(event.locationInWindow, from: nil)))
            return
        }
        let location = self.convert(event.locationInWindow, from: nil)
        defer {
            self.pressedQuotaDetails = false
            self.pressedTokenDetails = false
            self.pressedResetCards = false
            self.lastDragLocation = nil
            self.totalDragDistance = 0
        }
        if self.totalDragDistance >= 4 {
            self.delegate?.orbViewDidFinishDragging(self)
        } else if event.clickCount == 1, self.pressedQuotaDetails, self.quotaDetailsRect.contains(location) {
            self.delegate?.orbViewDidRequestQuotaDetails(self)
        } else if event.clickCount == 1, self.pressedTokenDetails, self.tokenConsumptionContains(location) {
            self.delegate?.orbViewDidRequestTokenDetails(self)
        } else if self.pressedResetCards, self.resetCardsRect.contains(location) {
            self.delegate?.orbViewDidRequestResetCards(self)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        menu.delegate = self
        let refresh = NSMenuItem(title: L10n.text("刷新"), action: #selector(self.refresh(_:)), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)
        let settings = NSMenuItem(title: L10n.text("设置…"), action: #selector(self.settings(_:)), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: L10n.text("退出 CodexOrb"), action: #selector(self.quit(_:)), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        // Keep the menu's available space independent of the small nonactivating panel.
        let location = self.window?.convertPoint(toScreen: event.locationInWindow) ?? self.screenLocation(of: event)
        menu.popUp(positioning: nil, at: location, in: nil)
    }

    func confinementRect(for menu: NSMenu, on screen: NSScreen?) -> NSRect {
        (screen ?? self.window?.screen ?? NSScreen.main)?.visibleFrame.insetBy(dx: 8, dy: 8) ?? .zero
    }

    @objc private func refresh(_ sender: Any?) {
        _ = sender
        self.delegate?.orbViewDidRequestRefresh(self)
    }

    @objc private func settings(_ sender: Any?) {
        _ = sender
        self.delegate?.orbViewDidRequestSettings(self)
    }

    @objc private func quit(_ sender: Any?) {
        _ = sender
        self.delegate?.orbViewDidRequestQuit(self)
    }

    private func drawCollapsed(in context: CGContext) {
        let colors = self.colors
        let capsule = self.bounds.insetBy(dx: 3, dy: 3)
        let radius = capsule.height / 2
        self.drawGlassBackground(in: capsule, cornerRadius: radius, colors: colors, context: context)

        let usage = self.displayState.usage
        let gauge = self.ringGauge
        self.drawRing(
            context: context,
            rect: gauge,
            remaining: usage?.ringQuota?.remainingPercent,
            width: 3.5,
            color: self.meterColor(for: usage?.ringQuota?.remainingPercent))
        self.drawWeeklyTimeRing(context: context, rect: gauge.insetBy(dx: -3.75, dy: -3.75))
        let fiveHourRemaining = usage?.fiveHourQuota?.remainingPercent
        self.drawText(
            usage?.ringQuota.map { "\(Int($0.remainingPercent.rounded()))%" } ?? "—",
            in: CGRect(x: gauge.minX, y: gauge.midY - 1,
                       width: gauge.width, height: 14),
            font: .monospacedDigitSystemFont(ofSize: 10.5, weight: .semibold),
            color: colors.primaryText,
            alignment: .center)
        self.drawText(
            fiveHourRemaining.map { "\(Int($0.rounded()))%" } ?? "--",
            in: CGRect(x: gauge.minX, y: gauge.midY - 13, width: gauge.width, height: 11),
            font: .monospacedDigitSystemFont(ofSize: 8.5, weight: .semibold),
            color: self.meterColor(for: fiveHourRemaining),
            alignment: .center)

        // Content stays anchored to the right edge and is covered by the moving ring.
        context.saveGState()
        context.clip(to: CGRect(x: 57, y: 3, width: max(0, self.bounds.width - 64), height: 50))
        let tokenRect = self.tokenConsumptionRect
        let topModelText = usage?.todayTokens?.modelUsages.first?.displayName ?? "—"

        if let today = usage?.todayTokens {
            self.drawText(
                Self.compactTokenCount(today.combinedTokens),
                in: tokenRect,
                font: .monospacedDigitSystemFont(ofSize: 16.5, weight: .semibold),
                color: colors.primaryText,
                alignment: .center)
        } else {
            let mainText: String
            if case .loading = self.displayState {
                mainText = "…"
            } else {
                mainText = "—"
            }
            self.drawText(
                mainText,
                in: tokenRect,
                font: .monospacedDigitSystemFont(ofSize: 16.5, weight: .semibold),
                color: colors.primaryText,
                alignment: .center)
        }
        self.drawText(
            topModelText,
            in: CGRect(
                x: tokenRect.minX,
                y: capsule.minY + 2,
                width: tokenRect.width,
                height: 14),
            font: .systemFont(ofSize: 11, weight: .medium),
            color: colors.secondaryText,
            alignment: .center)

        self.drawResetStack(colors: colors)
        context.restoreGState()

        if case .failed = self.displayState {
            let marker = CGRect(x: capsule.maxX - 11, y: capsule.maxY - 11, width: 7, height: 7)
            context.setFillColor(NSColor.systemRed.cgColor)
            context.fillEllipse(in: marker)
        } else if case .partial = self.displayState {
            let marker = CGRect(x: capsule.maxX - 11, y: capsule.maxY - 11, width: 7, height: 7)
            context.setFillColor(NSColor.systemOrange.cgColor)
            context.fillEllipse(in: marker)
        }
    }

    var quotaDetailsRect: CGRect {
        self.ringGauge.insetBy(dx: -4, dy: -4)
    }

    var tokenDetailsRect: CGRect {
        let tokenRect = self.tokenConsumptionRect
        // Keep the arrow near the capsule's outer edge so the card body has the
        // same breathing room as the reset-card popover.
        return tokenRect.offsetBy(dx: 0, dy: self.resetCardsRect.maxY - tokenRect.maxY)
    }

    var resetCardsRect: CGRect {
        CGRect(x: self.bounds.width - 120, y: 5, width: 44, height: 46)
    }

    private var ringGauge: CGRect {
        let capsule = self.bounds.insetBy(dx: 3, dy: 3)
        return CGRect(x: capsule.minX + 8, y: capsule.midY - 19, width: 38, height: 38)
    }

    private var tokenConsumptionRect: CGRect {
        let capsule = self.bounds.insetBy(dx: 3, dy: 3)
        let contentX = self.bounds.width - 176 + 56
        return CGRect(
            x: contentX + 38,
            y: capsule.midY - 9,
            width: 72,
            height: 23)
    }

    private func tokenConsumptionContains(_ point: CGPoint) -> Bool {
        guard self.bounds.width >= Self.minimumExpandedHitWidth else { return false }
        return self.tokenConsumptionRect.contains(point)
    }

    private func drawResetStack(colors: OrbColors) {
        let credits = self.displayState.usage?.resetCredits
        let count = credits?.availableCount ?? 0
        let front = CGRect(x: self.resetCardsRect.minX + 3, y: 7, width: 34, height: 38)
        let layers = min(2, max(0, count - 1))
        if layers > 0 {
            for layer in stride(from: layers, through: 1, by: -1) {
                let rect = front.offsetBy(dx: CGFloat(layer) * 2.5, dy: CGFloat(layer) * 2.5)
                let path = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
                NSColor.controlAccentColor.withAlphaComponent(0.10).setFill()
                path.fill()
                NSColor.controlAccentColor.withAlphaComponent(0.30).setStroke()
                path.lineWidth = 0.7
                path.stroke()
            }
        }
        let path = NSBezierPath(roundedRect: front, xRadius: 5, yRadius: 5)
        NSColor.windowBackgroundColor.setFill()
        path.fill()
        NSColor.controlAccentColor.withAlphaComponent(0.45).setStroke()
        path.lineWidth = 0.8
        path.stroke()
        self.drawText(credits.map { "↻\($0.availableCount)" } ?? "↻ —",
                      in: CGRect(x: front.minX, y: front.minY + 21, width: front.width, height: 15),
                      font: .monospacedDigitSystemFont(ofSize: 10, weight: .semibold),
                      color: colors.primaryText, alignment: .center)
        let expiry = count > 0 ? ResetCardsView.expirationText(credits?.nextExpiration, compact: true)
            : (credits == nil ? L10n.text("未知") : L10n.text("暂无"))
        let expiryColor = credits?.nextExpiration.map { self.resetExpirationColor($0, now: Date(), colors: colors) }
            ?? colors.secondaryText
        let expiryRect = CGRect(x: front.minX + 11, y: front.minY + 6, width: front.width - 13, height: 12)
        self.drawHourglass(
            in: CGRect(x: front.minX + 2, y: expiryRect.midY - 4 + 0.5, width: 8, height: 8),
            color: expiryColor)
        self.drawText(expiry,
                      in: expiryRect,
                      font: .monospacedDigitSystemFont(ofSize: 8, weight: .medium),
                      color: expiryColor, alignment: .center)
    }

    private func drawHourglass(in rect: CGRect, color: NSColor) {
        guard let symbol = NSImage(systemSymbolName: "hourglass", accessibilityDescription: nil),
              let configured = symbol.withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: rect.height, weight: .medium, scale: .small))
        else { return }
        let tinted = NSImage(size: rect.size)
        tinted.lockFocus()
        configured.draw(
            in: NSRect(origin: .zero, size: rect.size),
            from: .zero,
            operation: .sourceOver,
            fraction: 1)
        if let context = NSGraphicsContext.current?.cgContext {
            context.saveGState()
            context.setBlendMode(.sourceIn)
            context.setFillColor(color.cgColor)
            context.fill(CGRect(origin: .zero, size: rect.size))
            context.restoreGState()
        }
        tinted.unlockFocus()
        tinted.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
    }

    private func resetExpirationColor(_ expiration: Date, now: Date, colors: OrbColors) -> NSColor {
        expiration.timeIntervalSince(now) < 7 * 86_400 ? .systemOrange : colors.primaryText
    }

    private func updateSummaryToolTip() {
        switch self.displayState {
        case let .failed(_, message), let .partial(_, message): self.toolTip = message
        default: self.toolTip = nil
        }
    }

    private var weeklyResetDate: Date? {
        guard let usage = self.displayState.usage else { return nil }
        return [usage.weekly, usage.session]
            .compactMap { $0 }
            .first { $0.windowMinutes == 10_080 }?.resetsAt
    }

    private func drawWeeklyTimeRing(context: CGContext, rect: CGRect) {
        let remainingDays = self.weeklyResetDate.map {
            min(7, max(0, $0.timeIntervalSinceNow / 86_400))
        } ?? 0
        let step = 2 * CGFloat.pi / 7
        let gap: CGFloat = 0.10
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let tint = NSColor(red: 0.38, green: 0.28, blue: 0.95, alpha: 1)
        context.saveGState()
        context.setLineWidth(3)
        context.setLineCap(.butt)
        for index in 0..<7 {
            let start = CGFloat.pi / 2 + CGFloat(index) * step
            let sweep = step - gap
            context.setStrokeColor(tint.withAlphaComponent(0.18).cgColor)
            context.addArc(center: center, radius: rect.width / 2,
                           startAngle: start, endAngle: start + sweep, clockwise: false)
            context.strokePath()
            // Remaining time disappears counterclockwise from 12 o'clock.
            let fraction = min(1, max(0, remainingDays - Double(6 - index)))
            if fraction > 0 {
                context.setStrokeColor(tint.cgColor)
                context.addArc(center: center, radius: rect.width / 2,
                               startAngle: start + sweep * (1 - fraction),
                               endAngle: start + sweep, clockwise: false)
                context.strokePath()
            }
        }
        context.restoreGState()
    }

    private func drawRing(
        context: CGContext,
        rect: CGRect,
        remaining: Double?,
        width: CGFloat,
        color: NSColor)
    {
        context.setLineWidth(width)
        context.setLineCap(.round)
        context.setStrokeColor(self.colors.track.cgColor)
        context.strokeEllipse(in: rect)
        guard let remaining else { return }
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = rect.width / 2
        let start = CGFloat.pi / 2
        let end = start - (2 * CGFloat.pi * remaining / 100)
        context.setStrokeColor(color.cgColor)
        context.addArc(center: center, radius: radius, startAngle: start, endAngle: end, clockwise: true)
        context.strokePath()
    }

    private func drawGlassBackground(
        in rect: CGRect,
        cornerRadius: CGFloat,
        colors: OrbColors,
        context: CGContext)
    {
        let path = CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
        guard let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [colors.backgroundTop.cgColor, colors.backgroundBottom.cgColor] as CFArray,
            locations: [0, 1])
        else { return }

        context.saveGState()
        context.addPath(path)
        context.clip()
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: rect.minX, y: rect.maxY),
            end: CGPoint(x: rect.maxX, y: rect.minY),
            options: [])
        context.restoreGState()

        context.setStrokeColor(colors.highlight.cgColor)
        context.setLineWidth(1)
        context.addPath(CGPath(
            roundedRect: rect.insetBy(dx: 1.5, dy: 1.5),
            cornerWidth: max(0, cornerRadius - 1.5),
            cornerHeight: max(0, cornerRadius - 1.5),
            transform: nil))
        context.strokePath()
    }

    private func drawText(
        _ text: String,
        in rect: CGRect,
        font: NSFont,
        color: NSColor,
        alignment: NSTextAlignment)
    {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byTruncatingTail
        (text as NSString).draw(
            in: rect,
            withAttributes: [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: paragraph,
            ])
    }

    private func meterColor(for remaining: Double?) -> NSColor {
        guard let remaining else { return self.colors.secondaryText }
        return switch remaining {
        case ..<10: NSColor.systemRed
        case ..<30: NSColor.systemOrange
        default: NSColor.systemGreen
        }
    }

    private func updateAccessibility() {
        let value: String
        if let usage = self.displayState.usage {
            var parts: [String] = []
            if let ringRemaining = usage.ringQuota?.remainingPercent {
                parts.append(L10n.text("\(Int(ringRemaining.rounded())) % \(usage.provider) 额度剩余"))
            }
            if let pace = usage.weeklyPaceDeltaPercent {
                let rounded = Int(abs(pace).rounded())
                if pace >= 0.5 {
                    parts.append(L10n.text("\(rounded) % 周用量超出预期"))
                } else if pace <= -0.5 {
                    parts.append(L10n.text("\(rounded) % 周用量低于预期"))
                } else {
                    parts.append(L10n.text("周用量符合预期"))
                }
            }
            if let today = usage.todayTokens {
                parts.append(L10n.text("\(today.combinedTokens) 今日词元，包含缓存读取"))
                if !today.modelUsages.isEmpty {
                    parts.append(L10n.text("模型：\(today.modelUsages.map(\.displayName).joined(separator: " + "))"))
                }
            }
            if let resets = usage.resetCredits {
                parts.append(L10n.text("\(resets.availableCount) 次可用重置"))
                if let expiry = resets.nextExpiration {
                    parts.append(L10n.text("下次重置到期：\(expiry.formatted(Date.FormatStyle(date: .complete, time: .standard).locale(AppLanguage.load().locale)))"))
                }
            }
            value = parts.isEmpty ? L10n.text("用量暂不可用") : parts.joined(separator: ", ")
        } else if case .empty = self.displayState {
            value = L10n.text("暂无 CodexOrb 管理的账号")
        } else if case let .failed(_, message) = self.displayState {
            value = message
        } else {
            value = L10n.text("加载中")
        }
        self.setAccessibilityLabel(L10n.text("AI 额度与词元用量"))
        self.setAccessibilityValue(value)
    }

    private static func compactTokenCount(_ value: Int64) -> String {
        let amount = Double(value)
        switch value {
        case 1_000_000_000...:
            return String(format: "%.1fB", amount / 1_000_000_000)
        case 1_000_000...:
            return String(format: "%.1fM", amount / 1_000_000)
        case 1_000...:
            return String(format: "%.1fK", amount / 1_000)
        default:
            return "\(value)"
        }
    }

    private var colors: OrbColors {
        let dark = self.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return OrbColors(
            backgroundTop: dark
                ? NSColor(calibratedRed: 0.12, green: 0.14, blue: 0.18, alpha: 1)
                : NSColor.white.withAlphaComponent(1),
            backgroundBottom: dark
                ? NSColor(calibratedRed: 0.05, green: 0.06, blue: 0.09, alpha: 1)
                : NSColor(calibratedRed: 0.91, green: 0.94, blue: 0.98, alpha: 1),
            border: dark ? NSColor.white.withAlphaComponent(0.22) : NSColor.white.withAlphaComponent(0.86),
            highlight: dark ? NSColor.white.withAlphaComponent(0.14) : NSColor.white.withAlphaComponent(0.72),
            track: dark ? NSColor.white.withAlphaComponent(0.13) : NSColor.black.withAlphaComponent(0.09),
            primaryText: dark ? .white : .labelColor,
            secondaryText: dark ? NSColor.white.withAlphaComponent(0.65) : .secondaryLabelColor)
    }
}

private struct OrbColors {
    let backgroundTop: NSColor
    let backgroundBottom: NSColor
    let border: NSColor
    let highlight: NSColor
    let track: NSColor
    let primaryText: NSColor
    let secondaryText: NSColor
}
