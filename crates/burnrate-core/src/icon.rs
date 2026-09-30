//! The G2 "Dial Core" mark's state mapping: needle angle and severity tint.
//!
//! Shared by every platform renderer. The geometry itself (flame path, dial
//! hole, pivot) lives with each platform's renderer.
//!
//! Ported 1:1 from the Swift app's `IconSpec.swift`. Parity tests:
//! `StatusIconTests` — `needleAngleRestPoseAndExtremes`, `tintHitsTheSeverityStops`,
//! `tintInterpolatesBetweenStops`, `tintClampsOutOfRange`.

/// An 8-bit-per-channel colour, the form the severity ramp works in.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct RgbColor {
    pub red: f64,
    pub green: f64,
    pub blue: f64,
}

impl RgbColor {
    pub const fn new(red: f64, green: f64, blue: f64) -> Self {
        Self { red, green, blue }
    }

    /// `#RRGGBB`, for the frontend and for CSS.
    ///
    /// Truncates rather than rounds, matching the Swift helper. The ramp mixes
    /// floats, so 50% remaining lands on a value that is a hair under .5 and
    /// rounding would put the 50% tint 1/255 off the macOS build.
    pub fn to_hex(&self) -> String {
        let channel = |value: f64| {
            let byte = (value.clamp(0.0, 1.0) * 255.0) as u8;
            format!("{byte:02x}")
        };
        format!(
            "#{}{}{}",
            channel(self.red),
            channel(self.green),
            channel(self.blue)
        )
    }
}

/// A colour as raw 0–1 components, the form the ramp mixes in.
type Components = (f64, f64, f64);

/// One severity ramp stop: the remaining-% threshold and its top/bottom
/// gradient colours.
type Stop = (f64, Components, Components);

/// The gradient's top and bottom stops.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Tint {
    pub top: RgbColor,
    pub bottom: RgbColor,
}

pub struct StatusIcon;

impl StatusIcon {
    /// Needle angle from vertical: 100% remaining → 0°, 70% → 18° (rest pose),
    /// 0% → 60°. `None` renders the rest pose.
    pub fn needle_angle(remaining: Option<f64>) -> f64 {
        (100.0 - Self::clamped(remaining)) * 0.6
    }

    /// G2 severity ramp (top/bottom of the flame gradient): green ≥55,
    /// amber ~45, red ≤20.
    pub fn tint(remaining: Option<f64>) -> Tint {
        let value = Self::clamped(remaining);
        // (threshold, top, bottom)
        let stops: [Stop; 4] = [
            (55.0, rgb_hex(0x8F, 0xE0, 0x7A), rgb_hex(0x33, 0xAE, 0x70)),
            (45.0, rgb_hex(0xFF, 0xC2, 0x4B), rgb_hex(0xFF, 0x7A, 0x3D)),
            (20.0, rgb_hex(0xFF, 0x8A, 0x5C), rgb_hex(0xE6, 0x40, 0x19)),
            (0.0, rgb_hex(0xFF, 0x8A, 0x5C), rgb_hex(0xE6, 0x40, 0x19)),
        ];
        if value >= stops[0].0 {
            return Tint {
                top: RgbColor::new(stops[0].1 .0, stops[0].1 .1, stops[0].1 .2),
                bottom: RgbColor::new(stops[0].2 .0, stops[0].2 .1, stops[0].2 .2),
            };
        }
        for pair in stops.windows(2) {
            let (higher, lower) = (&pair[0], &pair[1]);
            if value >= lower.0 {
                let fraction = (higher.0 - value) / (higher.0 - lower.0);
                return Tint {
                    top: RgbColor::new(
                        mix(higher.1 .0, lower.1 .0, fraction),
                        mix(higher.1 .1, lower.1 .1, fraction),
                        mix(higher.1 .2, lower.1 .2, fraction),
                    ),
                    bottom: RgbColor::new(
                        mix(higher.2 .0, lower.2 .0, fraction),
                        mix(higher.2 .1, lower.2 .1, fraction),
                        mix(higher.2 .2, lower.2 .2, fraction),
                    ),
                };
            }
        }
        let last = stops[stops.len() - 1];
        Tint {
            top: RgbColor::new(last.1 .0, last.1 .1, last.1 .2),
            bottom: RgbColor::new(last.2 .0, last.2 .1, last.2 .2),
        }
    }

    fn clamped(remaining: Option<f64>) -> f64 {
        remaining.unwrap_or(70.0).clamp(0.0, 100.0)
    }
}

const fn rgb_hex(red: u8, green: u8, blue: u8) -> Components {
    (
        red as f64 / 255.0,
        green as f64 / 255.0,
        blue as f64 / 255.0,
    )
}

fn mix(a: f64, b: f64, fraction: f64) -> f64 {
    a + (b - a) * fraction
}

#[cfg(test)]
mod tests {
    use super::*;

    /// `needleAngleRestPoseAndExtremes` — 0°/18°/60° and the nil rest pose.
    #[test]
    fn needle_angle_rest_pose_and_extremes() {
        assert_eq!(StatusIcon::needle_angle(Some(100.0)), 0.0);
        assert_eq!(StatusIcon::needle_angle(Some(70.0)), 18.0);
        assert_eq!(StatusIcon::needle_angle(Some(0.0)), 60.0);
        // nil → rest pose, same as 70%.
        assert_eq!(StatusIcon::needle_angle(None), 18.0);
    }

    /// `tintHitsTheSeverityStops` — each stop's own colour.
    #[test]
    fn tint_hits_the_severity_stops() {
        // ≥55: green.
        assert_eq!(StatusIcon::tint(Some(100.0)).top.to_hex(), "#8fe07a");
        assert_eq!(StatusIcon::tint(Some(55.0)).top.to_hex(), "#8fe07a");
        // 45: amber.
        assert_eq!(StatusIcon::tint(Some(45.0)).top.to_hex(), "#ffc24b");
        // ≤20: red.
        assert_eq!(StatusIcon::tint(Some(20.0)).top.to_hex(), "#ff8a5c");
        assert_eq!(StatusIcon::tint(Some(0.0)).bottom.to_hex(), "#e64019");
    }

    /// `tintInterpolatesBetweenStops` — 50% sits between green and amber.
    #[test]
    fn tint_interpolates_between_stops() {
        let green = StatusIcon::tint(Some(55.0)).top;
        let amber = StatusIcon::tint(Some(45.0)).top;
        let mid = StatusIcon::tint(Some(50.0)).top;
        // Halfway between the two stops, per channel.
        assert!((mid.red - (green.red + amber.red) / 2.0).abs() < 0.01);
        assert!((mid.green - (green.green + amber.green) / 2.0).abs() < 0.01);
        assert!((mid.blue - (green.blue + amber.blue) / 2.0).abs() < 0.01);
    }

    /// `tintClampsOutOfRange` — values outside 0–100 clamp, and nil is the
    /// rest pose rather than an error.
    #[test]
    fn tint_clamps_out_of_range() {
        assert_eq!(StatusIcon::tint(Some(150.0)), StatusIcon::tint(Some(100.0)));
        assert_eq!(StatusIcon::tint(Some(-20.0)), StatusIcon::tint(Some(0.0)));
        assert_eq!(StatusIcon::tint(None), StatusIcon::tint(Some(70.0)));
    }
}
