import AppKit
import CodexOrbCore

@MainActor
final class QuotaDetailsView: NSView {
    private struct QuotaSpec {
        let kind: CodexQuotaWindow.Kind
        let remainingTitle: String
        let resetTitle: String
    }

    private struct DetailRow {
        enum Kind { case remaining, reset }

        let title: String
        let quota: CodexQuotaWindow
        let kind: Kind
    }

    private static let logicalWidth: CGFloat = 360
    private static let displayScale: CGFloat = 0.8
    private static let renderedWidth = QuotaDetailsView.logicalWidth * QuotaDetailsView.displayScale
    private static let baseLogicalHeight: CGFloat = 252
    private static let baseRowCount = 2
    private static let rowHeight: CGFloat = 56

    var onClose: (() -> Void)?
    private var usage: CodexUsage?
    private var forecast: CodexResetForecast?
    private var countdownTask: Task<Void, Never>?
    override var acceptsFirstResponder: Bool { true }

    init(usage: CodexUsage?, forecast: CodexResetForecast? = nil) {
        self.usage = usage
        self.forecast = forecast
        let rowCount = Self.detailRows(for: usage).count
        let logicalHeight = Self.contentHeight(rowCount: rowCount)
        super.init(frame: NSRect(x: 0, y: 0,
                                 width: Self.renderedWidth,
                                 height: logicalHeight * Self.displayScale))
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
        self.update(usage, forecast: self.forecast)
    }

    func update(_ usage: CodexUsage?, forecast: CodexResetForecast?) {
        self.usage = usage
        self.forecast = forecast
        self.rebuild()
    }

    private func rebuild() {
        let rows = Self.detailRows(for: self.usage)
        let logicalHeight = Self.contentHeight(rowCount: rows.count)
        var frame = self.frame
        frame.size = CGSize(width: Self.renderedWidth, height: logicalHeight * Self.displayScale)
        self.frame = frame
        self.bounds = NSRect(x: 0, y: 0, width: Self.logicalWidth, height: logicalHeight)
        self.subviews.forEach { $0.removeFromSuperview() }
        self.label(L10n.text("额度详情"), x: 18, y: logicalHeight - 36,
                   width: 324, size: 15, weight: .semibold)
        let now = Date()
        var rowY = logicalHeight - 76
        for row in rows {
            switch row.kind {
            case .remaining:
                self.quotaRow(row.title, quota: row.quota, y: rowY)
            case .reset:
                self.timeRow(row.title, quota: row.quota, now: now, y: rowY)
            }
            rowY -= Self.rowHeight
        }
        self.forecastSection()
    }

    private static func detailRows(for usage: CodexUsage?) -> [DetailRow] {
        self.quotaSpecs().flatMap { spec -> [DetailRow] in
            guard let quota = usage?.quota(for: spec.kind) else { return [] }
            var rows = [DetailRow(title: spec.remainingTitle, quota: quota, kind: .remaining)]
            if quota.resetsAt != nil {
                rows.append(DetailRow(title: spec.resetTitle, quota: quota, kind: .reset))
            }
            return rows
        }
    }

    private static func quotaSpecs() -> [QuotaSpec] {
        [
            QuotaSpec(
                kind: .fiveHour,
                remainingTitle: L10n.text("5 小时剩余额度"),
                resetTitle: L10n.text("5 小时重置剩余时间")),
            QuotaSpec(
                kind: .weekly,
                remainingTitle: L10n.text("周剩余额度"),
                resetTitle: L10n.text("周重置剩余时间")),
            QuotaSpec(
                kind: .monthly,
                remainingTitle: L10n.text("30 天剩余额度"),
                resetTitle: L10n.text("30 天重置剩余时间")),
        ]
    }

    private static func contentHeight(rowCount: Int) -> CGFloat {
        Self.baseLogicalHeight + CGFloat(max(0, rowCount - Self.baseRowCount)) * Self.rowHeight
    }

    private func forecastSection() {
        let separator = NSBox(frame: NSRect(x: 18, y: 86, width: 324, height: 2))
        separator.boxType = .separator
        self.addSubview(separator)
        self.label(L10n.text("全局重置预测"), x: 18, y: 60, width: 160, size: 13, weight: .semibold)
        self.forecastColumn(
            L10n.text("模型预测"),
            value: self.forecast?.probability24h,
            x: 18)
        self.forecastColumn(
            L10n.text("Tibo承诺"),
            value: self.forecast?.commitmentPercent,
            x: 192,
            emphasized: true)
    }

    private func forecastColumn(_ title: String, value: Int?, x: CGFloat, emphasized: Bool = false) {
        let width: CGFloat = 150
        let color: NSColor = emphasized ? .systemOrange : .labelColor
        let valueText = value.map { "\($0)%" } ?? L10n.text("未知")
        self.label(
            title,
            x: x,
            y: 31,
            width: 110,
            size: 12,
            weight: emphasized ? .semibold : .medium,
            color: color)
        self.label(
            valueText,
            x: x + 110,
            y: 31,
            width: 40,
            size: emphasized ? 14 : 13,
            weight: emphasized ? .bold : .regular,
            alignment: .right,
            color: color)
        let bar = QuotaDetailBar(frame: NSRect(x: x, y: emphasized ? 14 : 15,
                                             width: width, height: emphasized ? 9 : 7))
        bar.fraction = value.map { CGFloat($0) / CGFloat(100) }
        bar.tint = emphasized ? .systemOrange : .controlAccentColor
        bar.setAccessibilityElement(true)
        bar.setAccessibilityRole(.progressIndicator)
        bar.setAccessibilityLabel(title)
        bar.setAccessibilityValue(valueText)
        self.addSubview(bar)
    }

    private func quotaRow(_ title: String, quota: CodexQuotaWindow, y: CGFloat) {
        let remaining = quota.remainingPercent
        let value = String(format: "%.1f%%", remaining)
        let color: NSColor = remaining <= 10 ? .systemRed : (remaining <= 25 ? .systemOrange : .systemGreen)
        self.row(title, value: value, fraction: remaining / 100, color: color, y: y)
    }

    private func timeRow(_ title: String, quota: CodexQuotaWindow, now: Date, y: CGFloat) {
        guard let resetsAt = quota.resetsAt else { return }
        let seconds = max(0, resetsAt.timeIntervalSince(now))
        let duration = TimeInterval(quota.windowMinutes) * 60
        self.row(title, value: Self.countdown(seconds),
                 fraction: duration > 0 ? seconds / duration : nil, color: .systemTeal, y: y)
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
        self.label(title, x: 18, y: y, width: 185, size: 13, weight: .medium)
        self.label(value, x: 203, y: y, width: 139, size: 13, weight: .regular, alignment: .right)
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
                       weight: NSFont.Weight, alignment: NSTextAlignment = .left, height: CGFloat = 18,
                       color: NSColor = .labelColor) {
        let label = NSTextField(labelWithString: text)
        label.textColor = color
        label.font = .monospacedDigitSystemFont(ofSize: size, weight: weight)
        label.alignment = alignment
        label.frame = NSRect(x: x, y: y, width: width, height: height)
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
