import AppKit

/// Renders the G2 "Dial Core" mark: a flame with a gauge dial knocked into
/// it, needle reading remaining usage. 72-unit design space (y-down), from
/// the approved G2 sheet.
///
/// The mark is stateful: the needle angle and flame tint track the current
/// remaining % (green ≥55, amber ~45, red ≤20).
enum AppIconRenderer {
    // MARK: - Geometry (72-unit design space)

    /// Flame outline (FLO from the G2 sheet). Built lazily; treat as
    /// read-only (paths are only used for fill/clip, never mutated).
    private nonisolated(unsafe) static let flamePath: NSBezierPath = {
        let p = NSBezierPath()
        p.move(to: NSPoint(x: 36, y: 6))
        p.curve(to: NSPoint(x: 19.5, y: 27),
                controlPoint1: NSPoint(x: 33, y: 14), controlPoint2: NSPoint(x: 24, y: 20))
        p.curve(to: NSPoint(x: 15.5, y: 41),
                controlPoint1: NSPoint(x: 16.5, y: 32), controlPoint2: NSPoint(x: 15.5, y: 36.5))
        p.curve(to: NSPoint(x: 36, y: 60),
                controlPoint1: NSPoint(x: 15.5, y: 52), controlPoint2: NSPoint(x: 24.5, y: 60))
        p.curve(to: NSPoint(x: 56.5, y: 41),
                controlPoint1: NSPoint(x: 47.5, y: 60), controlPoint2: NSPoint(x: 56.5, y: 52))
        p.curve(to: NSPoint(x: 52.5, y: 27),
                controlPoint1: NSPoint(x: 56.5, y: 36.5), controlPoint2: NSPoint(x: 55.5, y: 32))
        p.curve(to: NSPoint(x: 36, y: 6),
                controlPoint1: NSPoint(x: 48, y: 20), controlPoint2: NSPoint(x: 39, y: 14))
        p.close()
        return p
    }()

    private static let dialCenter = NSPoint(x: 36, y: 42)
    private static let dialRadius: CGFloat = 10.5
    private static let pivot = NSPoint(x: 36, y: 46)
    private static let pivotRadius: CGFloat = 2.2
    private static let needleLength: CGFloat = 22
    private static let needleWidth: CGFloat = 2.6

    // MARK: - State mapping

    /// Needle angle from vertical: 100% remaining → 0°, 70% → 18° (G2 rest
    /// pose), 0% → 60°.
    static func needleAngle(forRemaining remaining: Double?) -> Double {
        let value = min(max(remaining ?? 70, 0), 100)
        return (100 - value) * 0.6
    }

    /// G2 severity ramp: green ≥55, amber ~45, red ≤20 (percent remaining).
    static func tint(forRemaining remaining: Double?) -> (top: NSColor, bottom: NSColor) {
        let value = min(max(remaining ?? 70, 0), 100)
        func rgb(_ hex: (UInt8, UInt8, UInt8)) -> NSColor {
            NSColor(calibratedRed: CGFloat(hex.0) / 255, green: CGFloat(hex.1) / 255, blue: CGFloat(hex.2) / 255, alpha: 1)
        }
        let stops: [(threshold: Double, a: (UInt8, UInt8, UInt8), b: (UInt8, UInt8, UInt8))] = [
            (100, (0x8F, 0xE0, 0x7A), (0x33, 0xAE, 0x70)),
            (55, (0x8F, 0xE0, 0x7A), (0x33, 0xAE, 0x70)),
            (45, (0xFF, 0xC2, 0x4B), (0xFF, 0x7A, 0x3D)),
            (20, (0xFF, 0x8A, 0x5C), (0xE6, 0x40, 0x19)),
            (0, (0xFF, 0x8A, 0x5C), (0xE6, 0x40, 0x19)),
        ]
        guard value < stops[0].threshold else { return (rgb(stops[0].a), rgb(stops[0].b)) }
        for (higher, lower) in zip(stops, stops.dropFirst()) where value >= lower.threshold {
            let fraction = CGFloat((higher.threshold - value) / (higher.threshold - lower.threshold))
            let mix = { (c1: (UInt8, UInt8, UInt8), c2: (UInt8, UInt8, UInt8)) -> NSColor in
                NSColor(calibratedRed: CGFloat(c1.0) + (CGFloat(c2.0) - CGFloat(c1.0)) * fraction,
                        green: CGFloat(c1.1) + (CGFloat(c2.1) - CGFloat(c1.1)) * fraction,
                        blue: CGFloat(c1.2) + (CGFloat(c2.2) - CGFloat(c1.2)) * fraction, alpha: 1)
            }
            return (mix(higher.a, lower.a), mix(higher.b, lower.b))
        }
        return (rgb(stops.last!.a), rgb(stops.last!.b))
    }

    // MARK: - Renderers

    /// Monochrome template image for the menu bar. Needle angle + dial hole
    /// reflect the current remaining % (nil → rest pose at 70%).
    static func menuBarImage(remaining: Double? = nil) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let scale = size.width / 72
        let angle = needleAngle(forRemaining: remaining)
        let image = NSImage(size: size, flipped: true) { _ in
            let context = NSGraphicsContext.current!.cgContext
            context.scaleBy(x: scale, y: scale)
            NSColor.black.setFill()
            flamePath.fill()
            // Dial core: punch a hole in the flame.
            context.setBlendMode(.destinationOut)
            NSColor.black.setFill()
            NSBezierPath(ovalIn: NSRect(x: dialCenter.x - dialRadius, y: dialCenter.y - dialRadius,
                                        width: dialRadius * 2, height: dialRadius * 2)).fill()
            context.setBlendMode(.normal)
            // Needle + pivot.
            NSColor.black.setStroke()
            needlePath(angle: angle).lineWidth = needleWidth
            needlePath(angle: angle).stroke()
            NSColor.black.setFill()
            NSBezierPath(ovalIn: NSRect(x: pivot.x - pivotRadius, y: pivot.y - pivotRadius,
                                        width: pivotRadius * 2, height: pivotRadius * 2)).fill()
            return true
        }
        image.isTemplate = true
        return image
    }

    /// Full-color app icon: G2 flame on the light plate. One icon serves
    /// Dock, notifications and About — macOS allows only a single app icon,
    /// so the plate (light, hairline border) keeps the thin flame legible on
    /// both dark banners and the light Dock grid.
    static func appIconImage(size: CGFloat = 512, remaining: Double? = nil, plate: Bool = true) -> NSImage {
        let scale = size / 72
        let angle = needleAngle(forRemaining: remaining)
        let tint = tint(forRemaining: remaining)
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { _ in
            let context = NSGraphicsContext.current!.cgContext
            context.scaleBy(x: scale, y: scale)
            // Light plate + hairline border for definition on any surface.
            if plate {
                NSColor(calibratedRed: 0xED / 255, green: 0xED / 255, blue: 0xF0 / 255, alpha: 1).setFill()
                NSBezierPath(roundedRect: NSRect(x: 1.5, y: 1.5, width: 69, height: 69),
                             xRadius: 16, yRadius: 16).fill()
                NSColor(calibratedWhite: 0.45, alpha: 1).setStroke()
                let border = NSBezierPath(roundedRect: NSRect(x: 1.5, y: 1.5, width: 69, height: 69),
                                          xRadius: 16, yRadius: 16)
                border.lineWidth = 1
                border.stroke()
            }
            // Flame filled with the severity gradient, clipped to its shape.
            context.saveGState()
            flamePath.addClip()
            NSGradient(starting: tint.bottom, ending: tint.top)?
                .draw(in: NSRect(x: 15.5, y: 6, width: 41, height: 54), angle: 90)
            context.restoreGState()
            // Dial core — dark, so on dark banners it reads as a knockout.
            NSColor(calibratedRed: 0x20 / 255, green: 0x0A / 255, blue: 0x02 / 255, alpha: 0.88).setFill()
            NSBezierPath(ovalIn: NSRect(x: dialCenter.x - dialRadius, y: dialCenter.y - dialRadius,
                                        width: dialRadius * 2, height: dialRadius * 2)).fill()
            // Needle + pivot.
            NSColor(calibratedRed: 0xFF / 255, green: 0xF6 / 255, blue: 0xEA / 255, alpha: 1).setStroke()
            needlePath(angle: angle).lineWidth = needleWidth
            needlePath(angle: angle).stroke()
            NSColor(calibratedRed: 0xFF / 255, green: 0xF6 / 255, blue: 0xEA / 255, alpha: 1).setFill()
            NSBezierPath(ovalIn: NSRect(x: pivot.x - pivotRadius, y: pivot.y - pivotRadius,
                                        width: pivotRadius * 2, height: pivotRadius * 2)).fill()
            return true
        }
        return image
    }

    private static func needlePath(angle: Double) -> NSBezierPath {
        let radians = angle * .pi / 180
        let path = NSBezierPath()
        path.move(to: pivot)
        path.line(to: NSPoint(x: pivot.x + needleLength * CGFloat(sin(radians)),
                              y: pivot.y - needleLength * CGFloat(cos(radians))))
        path.lineCapStyle = .round
        return path
    }

}
