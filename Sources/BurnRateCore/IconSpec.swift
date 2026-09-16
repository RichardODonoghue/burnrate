import Foundation

/// A platform-neutral RGB color (components 0…1) used by icon rendering.
public struct RGBColor: Sendable, Equatable {
    public let red: Double
    public let green: Double
    public let blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }
}

/// Pure state mapping for the status icon, shared by every platform renderer:
/// the needle angle and the severity gradient are platform-independent; only
/// converting `RGBColor` to a native color type is OS-specific.
public enum StatusIcon {
    /// Needle angle from vertical: 100% remaining → 0°, 70% → 18° (rest pose),
    /// 0% → 60°. `nil` renders the rest pose.
    public static func needleAngle(forRemaining remaining: Double?) -> Double {
        (100 - clamped(remaining)) * 0.6
    }

    /// G2 severity ramp (top/bottom of the flame gradient): green ≥55,
    /// amber ~45, red ≤20.
    public static func tint(forRemaining remaining: Double?) -> (top: RGBColor, bottom: RGBColor) {
        let value = clamped(remaining)
        let stops: [(threshold: Double, a: (Double, Double, Double), b: (Double, Double, Double))] = [
            (55, rgbHex(0x8F, 0xE0, 0x7A), rgbHex(0x33, 0xAE, 0x70)),
            (45, rgbHex(0xFF, 0xC2, 0x4B), rgbHex(0xFF, 0x7A, 0x3D)),
            (20, rgbHex(0xFF, 0x8A, 0x5C), rgbHex(0xE6, 0x40, 0x19)),
            (0, rgbHex(0xFF, 0x8A, 0x5C), rgbHex(0xE6, 0x40, 0x19)),
        ]
        guard value < stops[0].threshold else {
            return (RGBColor(stops[0].a), RGBColor(stops[0].b))
        }
        for (higher, lower) in zip(stops, stops.dropFirst()) where value >= lower.threshold {
            let fraction = (higher.threshold - value) / (higher.threshold - lower.threshold)
            return (RGBColor(mix(higher.a, lower.a, fraction)),
                    RGBColor(mix(higher.b, lower.b, fraction)))
        }
        return (RGBColor(stops.last!.a), RGBColor(stops.last!.b))
    }

    private static func clamped(_ remaining: Double?) -> Double {
        min(max(remaining ?? 70, 0), 100)
    }

    private static func mix(
        _ a: (Double, Double, Double),
        _ b: (Double, Double, Double),
        _ fraction: Double
    ) -> (Double, Double, Double) {
        (a.0 + (b.0 - a.0) * fraction,
         a.1 + (b.1 - a.1) * fraction,
         a.2 + (b.2 - a.2) * fraction)
    }
}

private extension RGBColor {
    init(_ components: (Double, Double, Double)) {
        self.init(red: components.0, green: components.1, blue: components.2)
    }
}

/// 0…1 components from a hex byte triple.
private func rgbHex(_ red: UInt8, _ green: UInt8, _ blue: UInt8) -> (Double, Double, Double) {
    (Double(red) / 255, Double(green) / 255, Double(blue) / 255)
}
