import AppKit

/// Renders the BurnRate mark "Dial Core": a flame with a dark gauge dial
/// knocked into it and a needle reading remaining usage. One 72-unit
/// geometry (y-down SVG space), three presentations:
/// menu-bar template (mono) · Dock/app icon (plate) · About pane.
enum AppIconRenderer {
    // MARK: - Geometry (72-unit design space, from the approved G2 sheet)

    private static let dialCenter = NSPoint(x: 36, y: 42)
    private static let dialRadius: CGFloat = 10.5
    private static let pivot = NSPoint(x: 36, y: 46)
    private static let pivotRadius: CGFloat = 2.2
    private static let needleLength: CGFloat = 22
    private static let needleWidth: CGFloat = 2.6
    /// Static rest angle (≈70% remaining), matching the shipped icon.
    private static let restAngle: Double = 18

    // MARK: - Public renderers

    /// Monochrome template image for the menu bar (alpha only, adapts to
    /// light/dark menu bars). The dial is knocked out of the flame; needle
    /// and pivot draw in ink. Pass `percentRemaining` to sweep the needle
    /// (−45° empty → +45° refilled); omit it to park at the rest angle.
    static func menuBarImage(percentRemaining: Double? = nil) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            drawG2(in: rect, mode: .mono(ink: .black), percentRemaining: percentRemaining)
            return true
        }
        image.isTemplate = true
        return image
    }

    /// Full-color app icon (Dock, notifications, About). Dark rounded plate,
    /// gradient flame, dark dial core, warm needle on top. Pass
    /// `percentRemaining` to tint the flame along the fresh→ember ramp;
    /// omit it for the static ember mark.
    static func appIconImage(size: CGFloat = 512, percentRemaining: Double? = nil) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            drawG2(in: rect, mode: .plate, percentRemaining: percentRemaining)
            return true
        }
    }

    /// Needle angle for a remaining-percent reading.
    /// Fuel-gauge semantics: E = empty (−45°) … F = refilled (+45°).
    static func needleAngle(percentRemaining: Double) -> Double {
        -45 + 0.9 * percentRemaining
    }

    /// Fresh→ember flame ramp, mirroring the approved G2 sheet: pure green
    /// ≥ 55%, green→amber blend 55→45, amber→red 45→20, ember red below.
    static func tint(percentRemaining p: Double) -> (top: NSColor, bottom: NSColor) {
        struct RGB { let r, g, b: CGFloat }
        func rgb(_ hex: UInt32) -> RGB {
            RGB(r: CGFloat((hex >> 16) & 0xFF) / 255,
                g: CGFloat((hex >> 8) & 0xFF) / 255,
                b: CGFloat(hex & 0xFF) / 255)
        }
        let stops: [(t: Double, top: RGB, bottom: RGB)] = [
            (100, rgb(0x8FE07A), rgb(0x33AE70)),
            (55,  rgb(0x8FE07A), rgb(0x33AE70)),
            (45,  rgb(0xFFC24B), rgb(0xFF7A3D)),
            (20,  rgb(0xFF8A5C), rgb(0xE64019)),
            (0,   rgb(0xFF8A5C), rgb(0xE64019)),
        ]
        func ns(_ c: RGB, alpha: CGFloat = 1) -> NSColor {
            NSColor(calibratedRed: c.r, green: c.g, blue: c.b, alpha: alpha)
        }
        guard let i = stops.firstIndex(where: { p >= $0.t }) else {
            return (ns(stops[0].top), ns(stops[0].bottom))
        }
        if i == 0 { return (ns(stops[0].top), ns(stops[0].bottom)) }
        let hi = stops[i], lo = stops[i - 1]
        let f = (lo.t - p) / (lo.t - hi.t)
        func mix(_ a: RGB, _ b: RGB) -> RGB {
            RGB(r: a.r + (b.r - a.r) * CGFloat(f),
                g: a.g + (b.g - a.g) * CGFloat(f),
                b: a.b + (b.b - a.b) * CGFloat(f))
        }
        return (ns(mix(lo.top, hi.top)), ns(mix(lo.bottom, hi.bottom)))
    }

    // MARK: - Drawing

    private enum Mode { case mono(ink: NSColor); case plate }

    private static func drawG2(in rect: NSRect, mode: Mode, percentRemaining: Double?) {
        let deg = percentRemaining.map(needleAngle(percentRemaining:)) ?? restAngle
        let (top, bottom) = percentRemaining.map(tint(percentRemaining:))
            ?? (NSColor(calibratedRed: 1.0, green: 0.62, blue: 0.20, alpha: 1),
                NSColor(calibratedRed: 0.90, green: 0.25, blue: 0.10, alpha: 1))

        let ctx = NSGraphicsContext.current!.cgContext
        let s = min(rect.width, rect.height) / 72
        ctx.saveGState()
        // Map SVG space: origin top-left, y-down, scaled to rect.
        ctx.translateBy(x: 0, y: rect.height)
        ctx.scaleBy(x: s, y: -s)

        switch mode {
        case .mono(let ink):
            ink.setFill()
            flamePath().fill()
            // Knock the dial out of the flame (alpha only).
            ctx.saveGState()
            ctx.setBlendMode(.destinationOut)
            NSColor.black.setFill()
            dialPath().fill()
            ctx.restoreGState()
            drawNeedle(deg: deg, stroke: ink)
        case .plate:
            NSColor(calibratedWhite: 26.0 / 255.0, alpha: 1).setFill()
            platePath().fill()
            // Flame with vertical gradient, clipped to the silhouette.
            ctx.saveGState()
            flamePath().addClip()
            let space = CGColorSpaceCreateDeviceRGB()
            let grad = CGGradient(colorsSpace: space,
                                  colors: [top.cgColor, bottom.cgColor] as CFArray,
                                  locations: [0, 1])!
            ctx.drawLinearGradient(grad,
                                   start: CGPoint(x: 36, y: 6),
                                   end: CGPoint(x: 36, y: 60), options: [])
            ctx.restoreGState()
            // Dial core over the flame.
            NSColor(calibratedRed: 0x20 / 255.0, green: 0x0A / 255.0, blue: 0x02 / 255.0,
                    alpha: 0.88).setFill()
            dialPath().fill()
            drawNeedle(deg: deg, stroke: NSColor(calibratedRed: 1.0, green: 0xF6 / 255.0,
                                                 blue: 0xEA / 255.0, alpha: 1))
        }
        ctx.restoreGState()
    }

    private static func drawNeedle(deg: Double, stroke: NSColor) {
        let r = deg * Double.pi / 180
        let tip = NSPoint(x: pivot.x + needleLength * CGFloat(sin(r)),
                          y: pivot.y - needleLength * CGFloat(cos(r)))
        let path = NSBezierPath()
        path.move(to: pivot)
        path.line(to: tip)
        path.lineCapStyle = .round
        stroke.setStroke()
        path.lineWidth = needleWidth
        path.stroke()
        stroke.setFill()
        NSBezierPath(ovalIn: NSRect(x: pivot.x - pivotRadius, y: pivot.y - pivotRadius,
                                    width: pivotRadius * 2, height: pivotRadius * 2)).fill()
    }

    private static func flamePath() -> NSBezierPath {
        let p = NSBezierPath()
        p.move(to: NSPoint(x: 36, y: 6))
        p.curve(to: NSPoint(x: 19.5, y: 27), controlPoint1: NSPoint(x: 33, y: 14),
                controlPoint2: NSPoint(x: 24, y: 20))
        p.curve(to: NSPoint(x: 15.5, y: 41), controlPoint1: NSPoint(x: 16.5, y: 32),
                controlPoint2: NSPoint(x: 15.5, y: 36.5))
        p.curve(to: NSPoint(x: 36, y: 60), controlPoint1: NSPoint(x: 15.5, y: 52),
                controlPoint2: NSPoint(x: 24.5, y: 60))
        p.curve(to: NSPoint(x: 56.5, y: 41), controlPoint1: NSPoint(x: 47.5, y: 60),
                controlPoint2: NSPoint(x: 56.5, y: 52))
        p.curve(to: NSPoint(x: 52.5, y: 27), controlPoint1: NSPoint(x: 56.5, y: 36.5),
                controlPoint2: NSPoint(x: 55.5, y: 32))
        p.curve(to: NSPoint(x: 36, y: 6), controlPoint1: NSPoint(x: 48, y: 20),
                controlPoint2: NSPoint(x: 39, y: 14))
        p.close()
        return p
    }

    private static func dialPath() -> NSBezierPath {
        NSBezierPath(ovalIn: NSRect(x: dialCenter.x - dialRadius, y: dialCenter.y - dialRadius,
                                    width: dialRadius * 2, height: dialRadius * 2))
    }

    private static func platePath() -> NSBezierPath {
        NSBezierPath(roundedRect: NSRect(x: 1.5, y: 1.5, width: 69, height: 69),
                     xRadius: 16, yRadius: 16)
    }
}
