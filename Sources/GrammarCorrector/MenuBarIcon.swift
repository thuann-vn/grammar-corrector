import AppKit

/// Colored menu bar icon: a gradient tile with a bold "A" and a green check badge.
/// Drawn in code (not a template image) so it stays colorful and stands out.
enum MenuBarIcon {
    static let normal = make(busy: false)
    static let busy = make(busy: true)

    static func make(busy: Bool) -> NSImage {
        let size = NSSize(width: 22, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            // Tile
            let tile = NSRect(x: 1, y: 1, width: 16, height: 16)
            let tilePath = NSBezierPath(roundedRect: tile, xRadius: 4.5, yRadius: 4.5)
            NSGradient(colors: [
                NSColor(srgbRed: 0.55, green: 0.30, blue: 1.00, alpha: 1),
                NSColor(srgbRed: 0.15, green: 0.50, blue: 1.00, alpha: 1),
            ])!.draw(in: tilePath, angle: -45)

            // Letter
            let font = NSFont.systemFont(ofSize: 12.5, weight: .heavy)
            let letter = NSAttributedString(string: "A", attributes: [
                .font: font,
                .foregroundColor: NSColor.white,
            ])
            let letterSize = letter.size()
            letter.draw(at: NSPoint(x: tile.midX - letterSize.width / 2,
                                    y: tile.midY - letterSize.height / 2 + 0.5))

            // Badge (green check, or orange dots while checking)
            let badge = NSRect(x: 12, y: 0, width: 10, height: 10)
            let badgePath = NSBezierPath(ovalIn: badge)
            (busy ? NSColor.systemOrange : NSColor(srgbRed: 0.12, green: 0.80, blue: 0.38, alpha: 1)).setFill()
            badgePath.fill()
            NSColor.white.setStroke()
            badgePath.lineWidth = 1.2
            badgePath.stroke()

            NSColor.white.set()
            if busy {
                for i in 0..<3 {
                    NSBezierPath(ovalIn: NSRect(x: badge.minX + 2.2 + CGFloat(i) * 2.1,
                                                y: badge.midY - 0.8, width: 1.6, height: 1.6)).fill()
                }
            } else {
                let check = NSBezierPath()
                check.move(to: NSPoint(x: badge.minX + 2.6, y: badge.midY + 0.2))
                check.line(to: NSPoint(x: badge.minX + 4.3, y: badge.minY + 2.8))
                check.line(to: NSPoint(x: badge.maxX - 2.4, y: badge.maxY - 2.8))
                check.lineWidth = 1.6
                check.lineCapStyle = .round
                check.lineJoinStyle = .round
                check.stroke()
            }
            return true
        }
        image.isTemplate = false
        return image
    }
}
