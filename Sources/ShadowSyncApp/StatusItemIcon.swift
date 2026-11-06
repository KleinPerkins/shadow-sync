import AppKit

enum ShadowSyncStatusItemIcon {
    private static let canvas = CGFloat(18)
    private static let scale = canvas / 24

    static func make() -> NSImage {
        let size = NSSize(width: canvas, height: canvas)
        let image = NSImage(size: size, flipped: false) { _ in
            NSColor.black.setStroke()
            let path = NSBezierPath()
            path.lineWidth = 2 * scale
            path.lineCapStyle = .round
            path.lineJoinStyle = .round

            appendCircle(x: 18, y: 18, radius: 3, to: path)
            appendCircle(x: 6, y: 6, radius: 3, to: path)
            appendLine(x: 18, fromY: 6, toY: 5, to: path)
            appendLine(x: 18, fromY: 11, toY: 10, to: path)
            appendLine(x: 6, fromY: 9, toY: 21, to: path)
            path.stroke()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "ShadowSync"
        return image
    }

    private static func appendCircle(
        x: CGFloat,
        y: CGFloat,
        radius: CGFloat,
        to path: NSBezierPath
    ) {
        let center = point(x: x, y: y)
        let scaledRadius = radius * scale
        path.appendOval(in: NSRect(
            x: center.x - scaledRadius,
            y: center.y - scaledRadius,
            width: scaledRadius * 2,
            height: scaledRadius * 2
        ))
    }

    private static func appendLine(
        x: CGFloat,
        fromY: CGFloat,
        toY: CGFloat,
        to path: NSBezierPath
    ) {
        path.move(to: point(x: x, y: fromY))
        path.line(to: point(x: x, y: toY))
    }

    private static func point(x: CGFloat, y: CGFloat) -> NSPoint {
        NSPoint(x: x * scale, y: canvas - y * scale)
    }
}
