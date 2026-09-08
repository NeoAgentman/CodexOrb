import Foundation

/// Window geometry in screen points; drawing stays in the original logical coordinates.
enum CapsuleGeometry {
    static let minimumScale: CGFloat = 1
    static let maximumScale: CGFloat = 1.5

    struct Edge: OptionSet {
        let rawValue: Int
        static let left = Edge(rawValue: 1)
        static let right = Edge(rawValue: 2)
        static let bottom = Edge(rawValue: 4)
        static let top = Edge(rawValue: 8)
    }

    /// The hit band follows the visible rounded capsule, including its curved ends.
    static func resizeEdge(at point: CGPoint, bounds: CGRect, scale: CGFloat) -> Edge {
        guard bounds.contains(point) else { return [] }
        let capsule = bounds.insetBy(dx: 3, dy: 3)
        let radius = capsule.height / 2
        let centerX = min(max(point.x, capsule.minX + radius), capsule.maxX - radius)
        let dx = point.x - centerX
        let dy = point.y - capsule.midY
        guard hypot(dx, dy) >= radius - 6 / max(1, scale) else { return [] }
        var edge: Edge = []
        if abs(dx) >= abs(dy) * 0.5, dx != 0 { edge.insert(dx < 0 ? .left : .right) }
        if abs(dy) >= abs(dx) * 0.5, dy != 0 { edge.insert(dy < 0 ? .bottom : .top) }
        return edge
    }

    static func scale(_ value: CGFloat) -> CGFloat {
        value.isFinite ? min(maximumScale, max(minimumScale, value)) : minimumScale
    }

    static func resizedFrame(start: CGRect, delta: CGPoint, edge: Edge, expanded: Bool,
                             maximumScale: CGFloat = maximumScale, logicalWidth: CGFloat? = nil) -> CGRect {
        let base = CGSize(width: logicalWidth ?? (expanded ? 176 : 60), height: 56)
        let x: CGFloat = edge.contains(.right) ? 1 : edge.contains(.left) ? -1 : 0
        let y: CGFloat = edge.contains(.top) ? 1 : edge.contains(.bottom) ? -1 : 0
        let denominator = x * x * base.width * base.width + y * y * base.height * base.height
        guard denominator > 0 else { return start }
        let change = (delta.x * x * base.width + delta.y * y * base.height) / denominator
        let factor = min(scale(start.height / base.height + change), max(minimumScale, maximumScale))
        let size = CGSize(width: base.width * factor, height: base.height * factor)
        return CGRect(x: x < 0 ? start.maxX - size.width : x > 0 ? start.minX : start.midX - size.width / 2,
                      y: y < 0 ? start.maxY - size.height : y > 0 ? start.minY : start.midY - size.height / 2,
                      width: size.width, height: size.height)
    }
}
