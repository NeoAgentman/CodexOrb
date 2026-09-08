import AppKit
import CodexOrbCore

@MainActor
final class QuotaDetailsView: NSView {
    var onClose: (() -> Void)?
    private var usage: CodexUsage?
    private var countdownTask: Task<Void, Never>?
    override var acceptsFirstResponder: Bool { true }

    init(usage: CodexUsage?) {
        self.usage = usage
        super.init(frame: NSRect(x: 0, y: 0, width: 288, height: 227.2))
        // Scale the complete card uniformly, including labels, bars and spacing.
        self.bounds = NSRect(x: 0, y: 0, width: 360, height: 284)
        self.rebuild()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func cancelOperation(_ sender: Any?) { self.onClose?() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        self.countdownTask?.cancel()
        guard self.window != nil else { return }
        self.countdownTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
                guard let self else { return }
                self.rebuild()
            }
        }
    }

    func update(_ usage: CodexUsage?) {
        self.usage = usage
        self.rebuild()
    }

    private func rebuild() {
        self.subviews.forEach { $0.removeFromSuperview() }
        self.label(L10n.text("额度详情"), x: 18, y: 249, width: 324, size: 13, weight: .semibold)
        let fiveHour = self.usage?.fiveHourQuota
        // Identify the actual weekly window, including reversed primary/secondary slots.
        let weekly = [self.usage?.session, self.usage?.weekly].compactMap { $0 }
            .first { $0.windowMinutes == 10_080 }
        let now = Date()
        self.quotaRow(L10n.text("5 小时剩余额度"), quota: fiveHour, y: 209)
        self.timeRow(L10n.text("5 小时重置剩余时间"), quota: fiveHour, duration: 5 * 3600, now: now, y: 153)
        self.quotaRow(L10n.text("周剩余额度"), quota: weekly, y: 97)
        self.timeRow(L10n.text("周重置剩余时间"), quota: weekly, duration: 7 * 86400, now: now, y: 41)
    }

    private func quotaRow(_ title: String, quota: CodexQuotaWindow?, y: CGFloat) {
        let remaining = quota?.remainingPercent
        let value = remaining.map { String(format: "%.1f%%", $0) } ?? L10n.text("暂不可用")
        let color: NSColor = remaining.map { $0 <= 10 ? .systemRed : ($0 <= 25 ? .systemOrange : .systemGreen) } ?? .tertiaryLabelColor
        self.row(title, value: value, fraction: remaining.map { $0 / 100 }, color: color, y: y)
    }

    private func timeRow(_ title: String, quota: CodexQuotaWindow?, duration: TimeInterval, now: Date, y: CGFloat) {
        let seconds = quota?.resetsAt.map { max(0, $0.timeIntervalSince(now)) }
        self.row(title, value: seconds.map(Self.countdown) ?? L10n.text("暂不可用"),
                 fraction: seconds.map { $0 / duration }, color: .systemTeal, y: y)
    }

    static func countdown(_ seconds: TimeInterval) -> String {
        if seconds <= 0 { return L10n.text("等待重置") }
        if seconds < 60 { return L10n.text("不足 1 分钟") }
        let minutes = Int(seconds / 60)
        if minutes >= 1440 {
            return L10n.text("\(minutes / 1440)天 \(minutes % 1440 / 60)小时 \(minutes % 60)分")
        }
        return L10n.text("\(minutes / 60)小时 \(minutes % 60)分")
    }

    private func row(_ title: String, value: String, fraction: Double?, color: NSColor, y: CGFloat) {
        self.label(title, x: 18, y: y, width: 185, size: 11, weight: .medium)
        self.label(value, x: 203, y: y, width: 139, size: 11, weight: .regular, alignment: .right)
        let bar = QuotaDetailBar(frame: NSRect(x: 18, y: y - 16, width: 324, height: 7))
        bar.fraction = fraction
        bar.tint = color
        bar.setAccessibilityElement(true)
        bar.setAccessibilityRole(.progressIndicator)
        bar.setAccessibilityLabel(title)
        bar.setAccessibilityValue(value)
        self.addSubview(bar)
    }

    private func label(_ text: String, x: CGFloat, y: CGFloat, width: CGFloat, size: CGFloat,
                       weight: NSFont.Weight, alignment: NSTextAlignment = .left) {
        let label = NSTextField(labelWithString: text)
        label.font = .monospacedDigitSystemFont(ofSize: size, weight: weight)
        label.alignment = alignment
        label.frame = NSRect(x: x, y: y, width: width, height: 18)
        self.addSubview(label)
    }
}

@MainActor
private final class QuotaDetailBar: NSView {
    var fraction: Double?
    var tint: NSColor = .systemTeal

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let track = NSBezierPath(roundedRect: self.bounds, xRadius: 3.5, yRadius: 3.5)
        NSColor.labelColor.withAlphaComponent(0.09).setFill()
        track.fill()
        guard let fraction, fraction.isFinite, fraction > 0 else { return }
        NSGraphicsContext.saveGraphicsState()
        track.addClip()
        self.tint.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: self.bounds.width * min(1, fraction), height: self.bounds.height)).fill()
        NSGraphicsContext.restoreGraphicsState()
    }
}
