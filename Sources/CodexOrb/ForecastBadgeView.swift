import AppKit
import CodexOrbCore

@MainActor
final class ForecastBadgeView: NSView {
    private let dayBadge = ProbabilityBadge(hours: 24)
    private let twoDayBadge = ProbabilityBadge(hours: 48)

    static func frame(capsuleFrame: CGRect, scale: CGFloat) -> CGRect {
        CGRect(x: capsuleFrame.maxX - AccountBadgeLayout.overlap,
               y: capsuleFrame.midY - 28 * scale,
               width: AccountBadgeLayout.badgeSize(scale: scale), height: 56 * scale)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        self.addSubview(self.dayBadge)
        self.addSubview(self.twoDayBadge)
        self.update(nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        let size = self.bounds.width
        self.dayBadge.frame = CGRect(x: 0, y: self.bounds.height - size, width: size, height: size)
        self.twoDayBadge.frame = CGRect(x: 0, y: 0, width: size, height: size)
    }

    func update(_ forecast: CodexResetForecast?) {
        self.dayBadge.probability = forecast?.probability24h
        self.twoDayBadge.probability = forecast?.probability48h
    }

    func reloadLanguage() {
        self.dayBadge.updateAccessibility()
        self.twoDayBadge.updateAccessibility()
    }
}

@MainActor
private final class ProbabilityBadge: NSView {
    private let hours: Int
    var probability: Int? {
        didSet {
            self.needsDisplay = true
            self.updateAccessibility()
        }
    }

    init(hours: Int) {
        self.hours = hours
        super.init(frame: .zero)
        self.setAccessibilityElement(true)
        self.setAccessibilityRole(.staticText)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        self.needsDisplay = true
    }

    func updateAccessibility() {
        let horizon = L10n.text(self.hours == 24 ? "24 小时内" : "48 小时内")
        self.setAccessibilityLabel("\(L10n.text("全局重置预测")) · \(horizon)")
        self.setAccessibilityValue(self.probability.map { "\($0)%" } ?? L10n.text("未知"))
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let colors = CapsuleSurfaceColors.resolved(for: self.effectiveAppearance)
        let rect = self.bounds.insetBy(dx: 2.5, dy: 2.5)
        colors.drawBackground(in: rect, cornerRadius: rect.height / 2, context: context)
        let outline = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
        colors.primaryText.withAlphaComponent(0.12).setStroke()
        outline.lineWidth = 0.5
        outline.stroke()
        let text = (self.probability.map { "\($0)%" } ?? "--") as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: rect.height * 0.32, weight: .medium),
            .foregroundColor: colors.primaryText,
        ]
        let size = text.size(withAttributes: attributes)
        text.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
                  withAttributes: attributes)
    }
}
