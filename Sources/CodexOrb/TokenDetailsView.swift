import AppKit
import CodexOrbCore

@MainActor
final class TokenDetailsView: NSView {
    private struct UsageRow {
        let name: String
        let tokens: Int64?
    }

    private static let logicalWidth: CGFloat = 360
    private static let displayScale: CGFloat = 0.8
    private static let rowHeight: CGFloat = 24
    private static let renderedWidth = TokenDetailsView.logicalWidth * TokenDetailsView.displayScale
    private static let barColors = [
        NSColor(calibratedRed: 0.15, green: 0.38, blue: 0.90, alpha: 1),
        NSColor(calibratedRed: 0.46, green: 0.12, blue: 0.83, alpha: 1),
        NSColor(calibratedRed: 0.12, green: 0.63, blue: 0.36, alpha: 1),
        NSColor(calibratedRed: 0.92, green: 0.47, blue: 0.10, alpha: 1),
    ]

    var onClose: (() -> Void)?
    private var usage: CodexUsage?
    override var acceptsFirstResponder: Bool { true }

    init(usage: CodexUsage?) {
        self.usage = usage
        super.init(frame: NSRect(x: 0, y: 0, width: Self.renderedWidth, height: 240))
        self.rebuild()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func cancelOperation(_ sender: Any?) { self.onClose?() }

    func update(_ usage: CodexUsage?) {
        self.usage = usage
        self.rebuild()
    }

    private func rebuild() {
        let today = self.usage?.todayTokens
        let tools = today?.toolUsages.map { UsageRow(name: $0.tool, tokens: $0.combinedTokens) } ?? []
        let models = today?.modelUsages.map { UsageRow(name: $0.displayName, tokens: $0.combinedTokens) } ?? []
        let logicalHeight = Self.contentHeight(toolCount: tools.count, modelCount: models.count)

        var frame = self.frame
        frame.size = CGSize(width: Self.renderedWidth, height: logicalHeight * Self.displayScale)
        self.frame = frame
        self.bounds = NSRect(x: 0, y: 0, width: Self.logicalWidth, height: logicalHeight)
        self.subviews.forEach { $0.removeFromSuperview() }

        self.label(L10n.text("Token 用量详情"), x: 18, y: logicalHeight - 24,
                   width: 324, size: 15, weight: .semibold)
        self.label(L10n.text("今日合计（含缓存读取）"), x: 18, y: logicalHeight - 54,
                   width: 220, size: 12, weight: .medium)
        self.label(today.map { Self.compactTokenCount($0.combinedTokens) } ?? L10n.text("暂不可用"),
                   x: 238, y: logicalHeight - 54, width: 104, size: 13,
                   weight: .semibold, alignment: .right)

        var cursor = logicalHeight - 84
        cursor = self.section(
            L10n.text("按工具"), rows: tools, totalTokens: today?.combinedTokens ?? 0, top: cursor)
        _ = self.section(
            L10n.text("按模型"), rows: models, totalTokens: today?.combinedTokens ?? 0, top: cursor)

        self.setAccessibilityElement(true)
        self.setAccessibilityRole(.group)
        self.setAccessibilityLabel(L10n.text("词元用量详情"))
        self.setAccessibilityValue(today.map { Self.compactTokenCount($0.combinedTokens) } ?? L10n.text("暂不可用"))
    }

    private static func contentHeight(toolCount: Int, modelCount: Int) -> CGFloat {
        let tools = CGFloat(max(1, toolCount))
        let models = CGFloat(max(1, modelCount))
        // Keep the last model row comfortably above the card's lower edge.
        return 16 + 24 + 12 + 18 + 12 + 18 + tools * Self.rowHeight + 14 + 18 + models * Self.rowHeight + 28
    }

    @discardableResult
    private func section(_ title: String, rows: [UsageRow], totalTokens: Int64, top: CGFloat) -> CGFloat {
        self.label(title, x: 18, y: top - 18, width: 324, size: 11,
                   weight: .semibold)
        let visibleRows = rows.isEmpty ? [UsageRow(name: L10n.text("无数据"), tokens: nil)] : rows
        var cursor = top - 30
        for (index, row) in visibleRows.enumerated() {
            let percentage = row.tokens.flatMap { Self.percentage($0, of: totalTokens) }
            let bar = TokenUsageBar(frame: NSRect(x: 100, y: cursor - 12, width: 142, height: 10))
            bar.fraction = percentage.map { $0 / 100 }
            bar.tint = Self.barColors[index % Self.barColors.count]
            bar.setAccessibilityElement(true)
            bar.setAccessibilityRole(.progressIndicator)
            bar.setAccessibilityLabel(row.name)
            bar.setAccessibilityValue(row.tokens.map(Self.compactTokenCount) ?? L10n.text("暂不可用"))
            self.addSubview(bar)

            self.label(row.name, x: 18, y: cursor - 17, width: 76, size: 12, weight: .regular)
            self.label(row.tokens.map(Self.compactTokenCount) ?? "—", x: 250, y: cursor - 17,
                       width: 92, size: 11, weight: .medium, alignment: .right, numeric: true)
            cursor -= Self.rowHeight
        }
        return cursor - 14
    }

    private func label(_ text: String, x: CGFloat, y: CGFloat, width: CGFloat, size: CGFloat,
                       weight: NSFont.Weight, color: NSColor = .labelColor,
                       alignment: NSTextAlignment = .left, numeric: Bool = false) {
        let label = NSTextField(labelWithString: text)
        label.font = numeric
            ? .monospacedDigitSystemFont(ofSize: size, weight: weight)
            : .systemFont(ofSize: size, weight: weight)
        label.textColor = color
        label.alignment = alignment
        label.usesSingleLineMode = true
        label.lineBreakMode = .byTruncatingTail
        label.frame = NSRect(x: x, y: y, width: width, height: 18)
        self.addSubview(label)
    }

    private static func percentage(_ value: Int64, of total: Int64) -> Double? {
        guard total > 0 else { return nil }
        return min(100, max(0, Double(value) / Double(total) * 100))
    }

    private static func compactTokenCount(_ value: Int64) -> String {
        let amount = Double(value)
        if AppLanguage.load() == .chinese {
            switch value {
            case 100_000_000...: return String(format: "%.1f亿", amount / 100_000_000)
            case 10_000...: return String(format: "%.1f万", amount / 10_000)
            case 1_000...: return String(format: "%.1f千", amount / 1_000)
            default: return Self.formatTokens(value)
            }
        }
        switch value {
        case 1_000_000_000...: return String(format: "%.1fB", amount / 1_000_000_000)
        case 1_000_000...: return String(format: "%.1fM", amount / 1_000_000)
        case 1_000...: return String(format: "%.1fK", amount / 1_000)
        default: return Self.formatTokens(value)
        }
    }

    private static func formatTokens(_ value: Int64) -> String {
        let formatter = NumberFormatter()
        formatter.locale = AppLanguage.load().locale
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}

@MainActor
private final class TokenUsageBar: NSView {
    var fraction: Double? { didSet { self.needsDisplay = true } }
    var tint: NSColor = .systemBlue { didSet { self.needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let track = NSBezierPath(roundedRect: self.bounds,
                                 xRadius: self.bounds.height / 2,
                                 yRadius: self.bounds.height / 2)
        NSColor.labelColor.withAlphaComponent(0.08).setFill()
        track.fill()
        guard let fraction, fraction.isFinite, fraction > 0 else { return }
        NSGraphicsContext.saveGraphicsState()
        track.addClip()
        self.tint.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0,
                                  width: self.bounds.width * min(1, fraction),
                                  height: self.bounds.height)).fill()
        NSGraphicsContext.restoreGraphicsState()
    }
}
