import AppKit

/// Renders the BurnRate mark: a gauge dial over a flame. Used as the menu-bar
/// template icon, the app/Dock icon, and in the About pane — one drawing,
/// three presentations.
enum AppIconRenderer {
    /// Monochrome template image for the menu bar (alpha only, adapts to
    /// light/dark menu bars).
    static func menuBarImage() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.set()

            // Gauge dial: open arc across the top.
            let arc = NSBezierPath()
            arc.appendArc(withCenter: NSPoint(x: rect.midX, y: rect.midY - 1),
                          radius: 7.2, startAngle: 175, endAngle: 5, clockwise: true)
            arc.lineWidth = 1.7
            arc.lineCapStyle = .round
            arc.stroke()

            // Needle pointing up-left (low usage).
            let needle = NSBezierPath()
            needle.move(to: NSPoint(x: rect.midX, y: rect.midY - 1))
            needle.line(to: NSPoint(x: rect.midX - 4.6, y: rect.midY + 3.4))
            needle.lineWidth = 1.5
            needle.lineCapStyle = .round
            needle.stroke()

            // Flame below the dial.
            drawFlame(in: NSRect(x: rect.midX - 3.4, y: 1.2, width: 6.8, height: 8), tint: NSColor.black)
            return true
        }
        image.isTemplate = true
        return image
    }

    /// Full-color app icon (Dock, notifications, About). Dark rounded square,
    /// gradient flame, light gauge dial.
    static func appIconImage(size: CGFloat = 512) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            drawAppIcon(rect: rect)
            return true
        }
        return image
    }

    static func drawAppIcon(rect: NSRect) {
        let background = NSBezierPath(roundedRect: rect.insetBy(dx: rect.width * 0.02, dy: rect.height * 0.02),
                                      xRadius: rect.width * 0.22, yRadius: rect.width * 0.22)
        NSColor(calibratedWhite: 0.10, alpha: 1).setFill()
        background.fill()

        // Gauge dial.
        let arc = NSBezierPath()
        arc.appendArc(withCenter: NSPoint(x: rect.midX, y: rect.midY + rect.height * 0.06),
                      radius: rect.width * 0.34, startAngle: 170, endAngle: 10, clockwise: true)
        arc.lineWidth = rect.width * 0.055
        arc.lineCapStyle = .round
        NSColor(calibratedWhite: 0.92, alpha: 1).setStroke()
        arc.stroke()

        // Needle.
        let needle = NSBezierPath()
        needle.move(to: NSPoint(x: rect.midX, y: rect.midY + rect.height * 0.06))
        needle.line(to: NSPoint(x: rect.midX - rect.width * 0.24, y: rect.midY + rect.height * 0.24))
        needle.lineWidth = rect.width * 0.045
        needle.lineCapStyle = .round
        NSColor(calibratedWhite: 0.92, alpha: 1).setStroke()
        needle.stroke()

        // Gradient flame, masked by the symbol's alpha.
        let flameRect = NSRect(x: rect.midX - rect.width * 0.17,
                               y: rect.height * 0.12,
                               width: rect.width * 0.34,
                               height: rect.height * 0.40)
        drawFlame(in: flameRect, tint: nil)
    }

    /// Draws the flame symbol; gradient (tint == nil) for the app icon,
    /// solid tint for the menu-bar template.
    private static func drawFlame(in rect: NSRect, tint: NSColor?) {
        guard let symbol = NSImage(systemSymbolName: "flame.fill",
                                   accessibilityDescription: "BurnRate flame") else { return }
        let scaled = symbol.withSymbolConfiguration(.init(pointSize: rect.height, weight: .bold)) ?? symbol
        let target = NSImage(size: rect.size, flipped: false) { _ in
            symbol.draw(in: NSRect(origin: .zero, size: rect.size), from: .zero, operation: .copy, fraction: 1)
            if let tint {
                tint.set()
                NSRect(origin: .zero, size: rect.size).fill(using: .sourceAtop)
            } else {
                let gradient = NSGradient(starting: NSColor(calibratedRed: 1.0, green: 0.62, blue: 0.20, alpha: 1),
                                          ending: NSColor(calibratedRed: 0.90, green: 0.25, blue: 0.10, alpha: 1))
                NSGraphicsContext.current?.cgContext.setBlendMode(.sourceAtop)
                gradient?.draw(in: NSRect(origin: .zero, size: rect.size), angle: 90)
                NSGraphicsContext.current?.cgContext.setBlendMode(.normal)
            }
            return true
        }
        target.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
    }
}
