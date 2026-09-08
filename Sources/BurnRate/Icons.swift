import AppKit

/// Renders the BurnRate mark: a flame with a gauge needle laid over it.
/// One drawing, three presentations: menu-bar template, Dock/app icon,
/// About pane.
enum AppIconRenderer {
    /// Monochrome template image for the menu bar (alpha only, adapts to
    /// light/dark menu bars). The needle is knocked out of the flame
    /// silhouette so it reads at 18pt.
    static func menuBarImage() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            drawFlame(symbolName: "flame.fill",
                      in: rect.insetBy(dx: 1, dy: 1),
                      gradient: false)
            drawNeedle(base: NSPoint(x: rect.midX + 0.4, y: rect.height * 0.22),
                       length: rect.height * 0.68,
                       angleDegrees: 18,
                       pivotRadius: 1.15,
                       needleWidth: 1.5,
                       knockOutWidth: 3.4,
                       color: .black)
            return true
        }
        image.isTemplate = true
        return image
    }

    /// Full-color app icon (Dock, notifications, About). Dark rounded square,
    /// gradient flame, white needle laid on top.
    static func appIconImage(size: CGFloat = 512) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let background = NSBezierPath(roundedRect: rect.insetBy(dx: rect.width * 0.02, dy: rect.height * 0.02),
                                          xRadius: rect.width * 0.22, yRadius: rect.width * 0.22)
            NSColor(calibratedWhite: 0.10, alpha: 1).setFill()
            background.fill()

            drawFlame(symbolName: "flame.fill",
                      in: rect.insetBy(dx: rect.width * 0.16, dy: rect.height * 0.10),
                      gradient: true)
            drawNeedle(base: NSPoint(x: rect.midX + rect.width * 0.01, y: rect.height * 0.20),
                       length: rect.height * 0.62,
                       angleDegrees: 18,
                       pivotRadius: rect.width * 0.045,
                       needleWidth: rect.width * 0.05,
                       knockOutWidth: 0,
                       color: NSColor(calibratedWhite: 0.96, alpha: 1))
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

    /// Gauge needle from `base`, tilted `angleDegrees` from vertical.
    /// `knockOutWidth > 0` first clears a wider channel (so a dark needle
    /// stays visible over a dark flame in template images).
    private static func drawNeedle(
        base: NSPoint,
        length: CGFloat,
        angleDegrees: CGFloat,
        pivotRadius: CGFloat,
        needleWidth: CGFloat,
        knockOutWidth: CGFloat,
        color: NSColor
    ) {
        let angle = (90 - angleDegrees) * .pi / 180
        let tip = NSPoint(x: base.x + length * CGFloat(cos(angle)),
                          y: base.y + length * CGFloat(sin(angle)))
        let path = NSBezierPath()
        path.move(to: base)
        path.line(to: tip)
        path.lineCapStyle = .round

        if knockOutWidth > 0 {
            let knockOut = path.copy() as! NSBezierPath
            knockOut.lineWidth = knockOutWidth
            NSColor.black.setStroke()
            let context = NSGraphicsContext.current!.cgContext
            context.setBlendMode(.destinationOut)
            knockOut.stroke()
            context.setBlendMode(.normal)
        }

        color.setStroke()
        path.lineWidth = needleWidth
        path.stroke()

        // Pivot dot.
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: base.x - pivotRadius, y: base.y - pivotRadius,
                                    width: pivotRadius * 2, height: pivotRadius * 2)).fill()
    }
}
