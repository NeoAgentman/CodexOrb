import AppKit
import CodexOrbCore

@MainActor
protocol OrbViewDelegate: AnyObject {
    func orbView(_ view: OrbView, didDragBy delta: CGPoint)
    func orbViewDidFinishDragging(_ view: OrbView)
    func orbView(_ view: OrbView, didChangeHover isHovering: Bool)
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

    var dailyQuotaEnabled = false {
        didSet {
            self.updateAccessibility()
            self.updateSummaryToolTip()
            self.needsDisplay = true
        }
    }
    var dailyQuota: DailyQuotaUsage? {
        didSet {
            self.updateAccessibility()
            self.updateSummaryToolTip()
            self.needsDisplay = true
        }
    }

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
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            self.removeTrackingArea(trackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: self.bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil)
        self.addTrackingArea(trackingArea)
        self.trackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        _ = event
        self.delegate?.orbView(self, didChangeHover: true)
    }

    override func mouseExited(with event: NSEvent) {
        _ = event
        self.delegate?.orbView(self, didChangeHover: false)
    }

    override func mouseDown(with event: NSEvent) {
        _ = event
        self.pressedResetCards = self.resetCardsRect.contains(self.convert(event.locationInWindow, from: nil))
            && self.bounds.width >= Self.minimumExpandedHitWidth
        self.lastDragLocation = NSEvent.mouseLocation
        self.totalDragDistance = 0
    }

    override func mouseDragged(with event: NSEvent) {
        _ = event
        guard let previous = self.lastDragLocation else { return }
        let current = NSEvent.mouseLocation
        let delta = CGPoint(x: current.x - previous.x, y: current.y - previous.y)
        self.totalDragDistance += hypot(delta.x, delta.y)
        self.lastDragLocation = current
        self.delegate?.orbView(self, didDragBy: delta)
    }

    override func mouseUp(with event: NSEvent) {
        let location = self.convert(event.locationInWindow, from: nil)
        defer {
            self.pressedResetCards = false
            self.lastDragLocation = nil
            self.totalDragDistance = 0
        }
        if self.totalDragDistance >= 4 {
            self.delegate?.orbViewDidFinishDragging(self)
        } else if event.clickCount == 2, self.tokenConsumptionContains(location) {
            self.delegate?.orbViewDidRequestRefresh(self)
        } else if self.pressedResetCards, self.resetCardsRect.contains(location) {
            self.delegate?.orbViewDidRequestResetCards(self)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        menu.delegate = self
        let refresh = NSMenuItem(title: "刷新", action: #selector(self.refresh(_:)), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)
        let settings = NSMenuItem(title: "设置…", action: #selector(self.settings(_:)), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 CodexOrb", action: #selector(self.quit(_:)), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        // Keep the menu's available space independent of the small nonactivating panel.
        let location = self.window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
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
        self.drawPaceArc(context: context, rect: gauge)
        self.drawDailyQuotaArc(context: context, rect: gauge)
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
        let front = CGRect(x: self.resetCardsRect.minX + 3, y: 7, width: 30, height: 38)
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
        let expiry = count > 0 ? ResetCardsView.expirationText(credits?.nextExpiration)
            .replacingOccurrences(of: "天到期", with: "天")
            .replacingOccurrences(of: "小时到期", with: "时")
            .replacingOccurrences(of: "期限未知", with: "未知")
            .replacingOccurrences(of: "不足1小时", with: "<1时")
            .replacingOccurrences(of: "小时", with: "时") : (credits == nil ? "未知" : "暂无")
        self.drawText(expiry,
                      in: CGRect(x: front.minX, y: front.minY + 6, width: front.width, height: 12),
                      font: .monospacedDigitSystemFont(ofSize: 8, weight: .medium),
                      color: credits?.nextExpiration.map { self.resetExpirationColor($0, now: Date(), colors: colors) }
                        ?? colors.secondaryText, alignment: .center)
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

    private var dailyQuotaText: String {
        guard let daily = self.dailyQuota, Calendar.current.isDateInToday(daily.startedAt) else { return "—" }
        return "\(String(format: "%.1f", daily.consumedPercent))%"
    }

    private func drawDailyQuotaArc(context: CGContext, rect: CGRect) {
        guard self.dailyQuotaEnabled,
              let quota = self.displayState.usage?.ringQuota,
              quota.windowMinutes == 10_080,
              let daily = self.dailyQuota,
              Calendar.current.isDateInToday(daily.startedAt),
              daily.consumedPercent.isFinite,
              daily.consumedPercent > 0 else { return }
        // Keep today's spent segment on the quota ring, immediately after what remains.
        // Clamp at one full circle when today's journal spans a quota reset.
        let remaining = quota.remainingPercent
        let dayStartRemaining = min(100, remaining + daily.consumedPercent)
        guard dayStartRemaining > remaining else { return }
        let angle: (Double) -> CGFloat = { .pi / 2 - 2 * .pi * $0 / 100 }
        context.saveGState()
        context.setLineWidth(4)
        context.setLineCap(.butt)
        let tint = self.displayState.usage?.weeklyPaceDeltaPercent.map { self.paceArcColor($0) }
            ?? self.meterColor(for: remaining)
        // Use an opaque pale tint so an underlying pace arc cannot change its color.
        let dailyTint = tint.blended(withFraction: 0.15, of: .white) ?? tint
        let arc = CGMutablePath()
        arc.addArc(center: CGPoint(x: rect.midX, y: rect.midY), radius: rect.width / 2,
                   startAngle: angle(remaining), endAngle: angle(dayStartRemaining), clockwise: true)
        // Restore the track underneath so the pace overlay cannot fill the dash gaps.
        context.saveGState()
        context.addPath(arc)
        context.replacePathWithStrokedPath()
        context.clip()
        let capsule = self.bounds.insetBy(dx: 3, dy: 3)
        self.drawGlassBackground(in: capsule, cornerRadius: capsule.height / 2,
                                 colors: self.colors, context: context)
        context.restoreGState()
        context.setStrokeColor(self.colors.track.cgColor)
        context.addPath(arc)
        context.strokePath()
        context.setLineDash(phase: 0, lengths: [2.5, 1.5])
        context.setStrokeColor(dailyTint.cgColor)
        context.addPath(arc)
        context.strokePath()
        context.restoreGState()
    }

    private func drawPaceArc(context: CGContext, rect: CGRect) {
        guard let usage = self.displayState.usage,
              usage.ringQuota?.windowMinutes == 10_080,
              let remaining = usage.ringQuota?.remainingPercent,
              let delta = usage.weeklyPaceDeltaPercent else { return }
        let actual = min(100, max(0, remaining))
        let expected = min(100, max(0, actual + delta))
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = rect.width / 2
        let angle: (Double) -> CGFloat = { .pi / 2 - 2 * .pi * $0 / 100 }
        context.saveGState()
        context.setLineCap(.butt)
        context.setLineWidth(3.5)
        if abs(actual - expected) > 0.001 {
            context.setStrokeColor(self.paceArcColor(delta).cgColor)
            // A dashed deficit occupies spent quota; it must not look like remaining quota.
            if delta > 0 { context.setLineDash(phase: 0, lengths: [2, 1.5]) }
            context.addArc(center: center, radius: radius,
                           startAngle: angle(min(actual, expected)),
                           endAngle: angle(max(actual, expected)), clockwise: true)
            context.strokePath()
        }
        context.setLineDash(phase: 0, lengths: [])
        context.setStrokeColor(self.colors.primaryText.cgColor)
        context.setLineWidth(1.5)
        let marker = angle(expected)
        context.move(to: CGPoint(x: center.x + (radius - 2) * cos(marker),
                                 y: center.y + (radius - 2) * sin(marker)))
        context.addLine(to: CGPoint(x: center.x + (radius + 1) * cos(marker),
                                    y: center.y + (radius + 1) * sin(marker)))
        context.strokePath()
        context.restoreGState()
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

    private func paceArcColor(_ delta: Double) -> NSColor {
        if delta > 0 { return .systemOrange }
        if delta < 0 { return .systemBlue }
        return self.meterColor(for: self.displayState.usage?.ringQuota?.remainingPercent)
    }

    private func updateAccessibility() {
        let value: String
        if let usage = self.displayState.usage {
            var parts: [String] = []
            if let ringRemaining = usage.ringQuota?.remainingPercent {
                parts.append("\(Int(ringRemaining.rounded())) % \(usage.provider) 额度剩余")
            }
            if let pace = usage.weeklyPaceDeltaPercent {
                let rounded = Int(abs(pace).rounded())
                if pace >= 0.5 {
                    parts.append("\(rounded) % 周用量超出预期")
                } else if pace <= -0.5 {
                    parts.append("\(rounded) % 周用量低于预期")
                } else {
                    parts.append("周用量符合预期")
                }
            }
            if let today = usage.todayTokens {
                parts.append("\(today.combinedTokens) 今日词元，包含缓存读取")
                if !today.modelUsages.isEmpty {
                    parts.append("模型：\(today.modelUsages.map(\.displayName).joined(separator: " + "))")
                }
            }
            if let resets = usage.resetCredits {
                parts.append("\(resets.availableCount) 次可用重置")
                if let expiry = resets.nextExpiration {
                    parts.append("下次重置到期：\(expiry.formatted(date: .complete, time: .standard))")
                }
            }
            if self.dailyQuotaEnabled { parts.append("今日消耗周额度 \(self.dailyQuotaText)") }
            value = parts.isEmpty ? "用量暂不可用" : parts.joined(separator: ", ")
        } else if case let .failed(_, message) = self.displayState {
            value = message
        } else {
            value = "加载中"
        }
        self.setAccessibilityLabel("AI 额度与词元用量")
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
