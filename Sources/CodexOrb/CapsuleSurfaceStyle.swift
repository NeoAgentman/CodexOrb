import AppKit

struct CapsuleSurfaceColors {
    let backgroundTop: NSColor
    let backgroundBottom: NSColor
    let highlight: NSColor
    let track: NSColor
    let primaryText: NSColor
    let secondaryText: NSColor

    static func resolved(for appearance: NSAppearance) -> Self {
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return Self(
            backgroundTop: dark
                ? NSColor(calibratedRed: 0.12, green: 0.14, blue: 0.18, alpha: 1)
                : NSColor.white.withAlphaComponent(1),
            backgroundBottom: dark
                ? NSColor(calibratedRed: 0.05, green: 0.06, blue: 0.09, alpha: 1)
                : NSColor(calibratedRed: 0.91, green: 0.94, blue: 0.98, alpha: 1),
            highlight: dark ? NSColor.white.withAlphaComponent(0.14) : NSColor.white.withAlphaComponent(0.72),
            track: dark ? NSColor.white.withAlphaComponent(0.13) : NSColor.black.withAlphaComponent(0.09),
            primaryText: dark ? .white : .labelColor,
            secondaryText: dark ? NSColor.white.withAlphaComponent(0.65) : .secondaryLabelColor)
    }

    func drawBackground(in rect: CGRect, cornerRadius: CGFloat, context: CGContext) {
        let path = CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
        guard let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [self.backgroundTop.cgColor, self.backgroundBottom.cgColor] as CFArray,
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

        context.setStrokeColor(self.highlight.cgColor)
        context.setLineWidth(1)
        context.addPath(CGPath(
            roundedRect: rect.insetBy(dx: 1.5, dy: 1.5),
            cornerWidth: max(0, cornerRadius - 1.5),
            cornerHeight: max(0, cornerRadius - 1.5),
            transform: nil))
        context.strokePath()
    }
}
