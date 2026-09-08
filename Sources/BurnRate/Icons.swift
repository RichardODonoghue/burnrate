import AppKit

/// Renders the BurnRate mark: a flame rising out of a gauge dial at its
/// base — the flame is the needle. One drawing, three presentations:
/// menu-bar template, Dock/app icon, About pane.
enum AppIconRenderer {
    /// Monochrome template image for the menu bar (alpha only, adapts to
    /// light/dark menu bars).
    static func menuBarImage() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.set()
            // Flame rising from the dial, centered slightly high.
            drawFlame(symbolName: "flame.fill",
                      in: NSRect(x: rect.midX - 5, y: rect.height * 0.18,
                                 width: 10, height: rect.height * 0.76),
                      gradient: false)
            // Gauge dial at the flame's base.
            drawDial(center: NSPoint(x: rect.midX, y: rect.height * 0.18),
                     radius: 3.4, color: .black)
            return true
        }
        image.isTemplate = true
        return image
    }

    /// Full-color app icon (Dock, notifications, About). Dark rounded square,
    /// gradient flame rising from a light gauge dial.
    static func appIconImage(size: CGFloat = 512) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let background = NSBezierPath(roundedRect: rect.insetBy(dx: rect.width * 0.02, dy: rect.height * 0.02),
                                          xRadius: rect.width * 0.22, yRadius: rect.width * 0.22)
            NSColor(calibratedWhite: 0.10, alpha: 1).setFill()
            background.fill()

            drawFlame(symbolName: "flame.fill",
                      in: NSRect(x: rect.midX - rect.width * 0.24,
                                 y: rect.height * 0.22,
                                 width: rect.width * 0.48,
                                 height: rect.height * 0.68),
                      gradient: true)
            drawDial(center: NSPoint(x: rect.midX, y: rect.height * 0.24),
                     radius: rect.width * 0.15,
                     color: NSColor(calibratedWhite: 0.92, alpha: 1))
            return true
        }
    }

    // MARK: - Pieces

    /// Renders an SF Symbol, optionally filled with a vertical gradient
    /// (masked to the symbol's alpha via source-atop).
    private static func drawFlame(symbolName: String, in rect: NSRect, gradient: Bool) {
        guard let symbol = NSImage(systemSymbolName: symbolName,
                                   accessibilityDescription: "BurnRate") else { return }
        let scaled = symbol.withSymbolConfiguration(.init(pointSize: rect.height, weight: .bold)) ?? symbol
        let target = NSImage(size: rect.size, flipped: false) { _ in
            scaled.draw(in: NSRect(origin: .zero, size: rect.size), from: .zero, operation: .copy, fraction: 1)
            if gradient {
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

    /// Gauge dial at the flame's base: circle + needle pointing straight up,
    /// into the flame — the flame reads as the needle.
    private static func drawDial(center: NSPoint, radius: CGFloat, color: NSColor) {
        color.setStroke()
        let circle = NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius,
                                                 width: radius * 2, height: radius * 2))
        circle.lineWidth = radius * 0.24
        circle.stroke()

        let needle = NSBezierPath()
        needle.move(to: center)
        needle.line(to: NSPoint(x: center.x, y: center.y + radius * 0.95))
        needle.lineWidth = radius * 0.24
        needle.lineCapStyle = .round
        needle.stroke()
    }
}
