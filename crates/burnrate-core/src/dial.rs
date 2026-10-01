//! The G2 "Dial Core" mark: a flame with a gauge dial knocked into it, the
//! needle reading remaining usage.
//!
//! The mark is stateful — needle angle and flame tint both track remaining % —
//! and macOS renders one monochrome template image for the menu bar plus one
//! full-colour app icon.
//!
//! Geometry is a 72-unit design space, y-down, from the approved G2 sheet. All
//! paths are flat RGBA the runtime can hand straight to Tauri's `Image`, which
//! wants pixels rather than a PNG.
use crate::icon::{RgbColor, StatusIcon};

/// A point in the 72-unit design space.
type Point = [f64; 2];

/// One cubic Bézier segment of the flame outline, as (to, control1, control2,
/// from) — the reverse of how a drawing API would take it, so the segments read
/// in the order the flame is drawn.
type Segment = (Point, Point, Point, Point);

/// 72-unit design space: the flame outline, as cubic Béziers (FLO).
const FLAME: [Segment; 6] = [
    // (to, control1, control2, from)
    ([19.5, 27.0], [33.0, 14.0], [24.0, 20.0], [36.0, 6.0]),
    ([15.5, 41.0], [16.5, 32.0], [15.5, 36.5], [19.5, 27.0]),
    ([36.0, 60.0], [15.5, 52.0], [24.5, 60.0], [15.5, 41.0]),
    ([56.5, 41.0], [47.5, 60.0], [56.5, 52.0], [36.0, 60.0]),
    ([52.5, 27.0], [56.5, 36.5], [55.5, 32.0], [56.5, 41.0]),
    ([36.0, 6.0], [48.0, 20.0], [39.0, 14.0], [52.5, 27.0]),
];

/// The middle of the 72-unit design space.
const DESIGN_CENTRE: f64 = 36.0;

/// How much to magnify the mark for the menu bar, and about which point.
///
/// The flame ink spans design y 6.5…60 — deliberately padded inside the 72-unit
/// space, because the app icon draws a plate around it. `tray-icon` scales the
/// whole canvas to 18pt regardless, so that padding is subtracted from the drawn
/// size. 1.25 puts the ink at ~93% of the height, just inside the canvas, for a
/// mark of ~16pt rather than 13.4pt, with room at the flame's tip.
const MENU_BAR_ZOOM: f64 = 1.19;
const MENU_BAR_INK_CENTRE: [f64; 2] = [36.0, 33.25];

const DIAL_CENTER: [f64; 2] = [36.0, 42.0];
const DIAL_RADIUS: f64 = 10.5;
const PIVOT: [f64; 2] = [36.0, 46.0];
const PIVOT_RADIUS: f64 = 2.2;
const NEEDLE_LENGTH: f64 = 22.0;
const NEEDLE_WIDTH: f64 = 2.6;

const PLATE: RgbColor = RgbColor::new(
    0x1C as f64 / 255.0,
    0x1C as f64 / 255.0,
    0x1E as f64 / 255.0,
);
const DIAL_CORE: RgbColor = RgbColor::new(
    0x20 as f64 / 255.0,
    0x0A as f64 / 255.0,
    0x02 as f64 / 255.0,
);
const CREAM: RgbColor = RgbColor::new(1.0, 0xF6 as f64 / 255.0, 0xEA as f64 / 255.0);

/// A premultiplied-free RGBA canvas in the 72-unit design space.
pub struct Canvas {
    pub size: u32,
    pub pixels: Vec<u8>,
    /// Design-space zoom about `focus`. See [`Canvas::zoomed`].
    zoom: f64,
    focus: [f64; 2],
}

impl Canvas {
    pub fn new(size: u32) -> Self {
        Self {
            size,
            pixels: vec![0; (size * size * 4) as usize],
            zoom: 1.0,
            focus: [DESIGN_CENTRE, DESIGN_CENTRE],
        }
    }

    /// Magnifies the design space, placing `focus` at the canvas centre.
    ///
    /// The app icon and the menu-bar mark share geometry but not framing: the
    /// icon is a plate with deliberate padding, while `tray-icon` scales the whole
    /// *canvas* to a fixed 18pt, so padding in the design space is lost size rather
    /// than margin.
    ///
    /// `focus` is the mark's own ink centre rather than the canvas middle: the
    /// flame sits above it, so scaling about the canvas would leave it riding high.
    pub fn zoomed(mut self, zoom: f64, focus: [f64; 2]) -> Self {
        self.zoom = zoom;
        self.focus = focus;
        self
    }

    fn blend(&mut self, x: i64, y: i64, color: RgbColor, alpha: f64) {
        if alpha <= 0.0 {
            return;
        }
        let alpha = alpha.min(1.0);
        if x < 0 || y < 0 || x >= self.size as i64 || y >= self.size as i64 {
            return;
        }
        let index = ((y as u32 * self.size + x as u32) * 4) as usize;
        let dst_a = self.pixels[index + 3] as f64 / 255.0;
        let out_a = alpha + dst_a * (1.0 - alpha);
        if out_a <= 0.0 {
            return;
        }
        for channel in 0..3 {
            let src = [color.red, color.green, color.blue][channel];
            let dst = self.pixels[index + channel] as f64 / 255.0;
            let mixed = (src * alpha + dst * dst_a * (1.0 - alpha)) / out_a;
            self.pixels[index + channel] = (mixed.clamp(0.0, 1.0) * 255.0).round() as u8;
        }
        self.pixels[index + 3] = (out_a * 255.0).round() as u8;
    }

    /// Fills every pixel whose sample point is inside `shape`, with a vertical
    /// gradient between `top` and `bottom` across the shape's own bounds.
    fn fill_shape<F: Fn(f64, f64) -> bool>(
        &mut self,
        shape: F,
        top: RgbColor,
        bottom: RgbColor,
        y_range: (f64, f64),
    ) {
        let (y_min, y_max) = y_range;
        let span = (y_max - y_min).max(f64::EPSILON);
        for y in 0..self.size as i64 {
            for x in 0..self.size as i64 {
                let (px, py) = self.design_point(x, y);
                if !shape(px, py) {
                    continue;
                }
                // Gradients run bottom → top in the design space (y-down).
                let t = ((y_max - py) / span).clamp(0.0, 1.0);
                let color = RgbColor::new(
                    bottom.red + (top.red - bottom.red) * t,
                    bottom.green + (top.green - bottom.green) * t,
                    bottom.blue + (top.blue - bottom.blue) * t,
                );
                self.blend(x, y, color, 1.0);
            }
        }
    }

    /// Strokes a line of the given width in design units, round-capped.
    fn stroke_line(&mut self, from: [f64; 2], to: [f64; 2], width: f64, color: RgbColor) {
        let half = width / 2.0;
        let (dx, dy) = (to[0] - from[0], to[1] - from[1]);
        let length = (dx * dx + dy * dy).sqrt();
        if length <= f64::EPSILON {
            return;
        }
        let (ux, uy) = (dx / length, dy / length);
        for y in 0..self.size as i64 {
            for x in 0..self.size as i64 {
                let (px, py) = self.design_point(x, y);
                let t =
                    (((px - from[0]) * ux + (py - from[1]) * uy).clamp(0.0, length)).min(length);
                let cx = from[0] + ux * t;
                let cy = from[1] + uy * t;
                let distance = ((px - cx).powi(2) + (py - cy).powi(2)).sqrt();
                if distance <= half {
                    self.blend(x, y, color, 1.0);
                }
            }
        }
    }

    fn fill_oval(&mut self, center: [f64; 2], radius: f64, color: RgbColor) {
        let r2 = radius * radius;
        for y in 0..self.size as i64 {
            for x in 0..self.size as i64 {
                let (px, py) = self.design_point(x, y);
                let dx = px - center[0];
                let dy = py - center[1];
                if dx * dx + dy * dy <= r2 {
                    self.blend(x, y, color, 1.0);
                }
            }
        }
    }

    /// Strokes an oval of the given width in design units.
    fn stroke_oval(
        &mut self,
        center: [f64; 2],
        radius: f64,
        width: f64,
        color: RgbColor,
        alpha: f64,
    ) {
        let outer = radius + width / 2.0;
        let inner = radius - width / 2.0;
        for y in 0..self.size as i64 {
            for x in 0..self.size as i64 {
                let (px, py) = self.design_point(x, y);
                let d = ((px - center[0]).powi(2) + (py - center[1]).powi(2)).sqrt();
                if d <= outer && d >= inner {
                    self.blend(x, y, color, alpha);
                }
            }
        }
    }

    /// Fills a rounded rect inset by `inset` design units.
    fn fill_rounded_rect(&mut self, inset: f64, radius: f64, color: RgbColor) {
        let (lo, hi) = (inset, 72.0 - inset);
        for y in 0..self.size as i64 {
            for x in 0..self.size as i64 {
                let (px, py) = self.design_point(x, y);
                if px < lo || px > hi || py < lo || py > hi {
                    continue;
                }
                // Corner test against the nearest arc centre.
                let cx = px.clamp(lo + radius, hi - radius);
                let cy = py.clamp(lo + radius, hi - radius);
                let dx = px - cx;
                let dy = py - cy;
                if dx * dx + dy * dy <= radius * radius {
                    self.blend(x, y, color, 1.0);
                }
            }
        }
    }

    /// Maps a pixel to the y-down design space.
    fn design_point(&self, x: i64, y: i64) -> (f64, f64) {
        let scale = 72.0 / self.size as f64;
        let px = (x as f64 + 0.5) * scale;
        let py = (y as f64 + 0.5) * scale;
        if self.zoom == 1.0 {
            return (px, py);
        }
        // Inverted, and measured from the canvas centre: the centre pixel shows
        // `focus`, and a pixel `zoom` times further out shows the design point
        // that was that far from the centre, so the drawing comes out magnified
        // and centred on the ink rather than on the canvas.
        (
            self.focus[0] + (px - DESIGN_CENTRE) / self.zoom,
            self.focus[1] + (py - DESIGN_CENTRE) / self.zoom,
        )
    }
}

/// Is the point inside the flame outline?
///
/// The six Béziers form one closed contour, so containment is a single
/// even-odd ray cast across the whole flattened path — not a per-segment test,
/// which would report "inside" for any single segment the ray happens to cross.
pub fn in_flame(px: f64, py: f64) -> bool {
    let poly = flame_polyline();
    let mut inside = false;
    for index in 0..poly.len() {
        let a = poly[index];
        let b = poly[(index + 1) % poly.len()];
        if (a[1] > py) != (b[1] > py) {
            let t = (py - a[1]) / (b[1] - a[1]);
            let x_at = a[0] + (b[0] - a[0]) * t;
            if px < x_at {
                inside = !inside;
            }
        }
    }
    inside
}

/// The flame outline flattened to a polyline, for hit-testing.
fn flame_polyline() -> Vec<[f64; 2]> {
    const STEPS: usize = 32;
    let mut points: Vec<[f64; 2]> = Vec::with_capacity(FLAME.len() * STEPS);
    for (to, c1, c2, from) in FLAME {
        for step in 1..=STEPS {
            let t = step as f64 / STEPS as f64;
            let mt = 1.0 - t;
            points.push([
                mt * mt * mt * from[0]
                    + 3.0 * mt * mt * t * c1[0]
                    + 3.0 * mt * t * t * c2[0]
                    + t * t * t * to[0],
                mt * mt * mt * from[1]
                    + 3.0 * mt * mt * t * c1[1]
                    + 3.0 * mt * t * t * c2[1]
                    + t * t * t * to[1],
            ]);
        }
    }
    points
}

/// The needle's end point for an angle in degrees from vertical.
pub fn needle_tip(angle_degrees: f64) -> [f64; 2] {
    let radians = angle_degrees * std::f64::consts::PI / 180.0;
    [
        PIVOT[0] + NEEDLE_LENGTH * radians.sin(),
        PIVOT[1] - NEEDLE_LENGTH * radians.cos(),
    ]
}

/// Menu-bar icon: monochrome, so macOS recolours it (and so it stays legible
/// in light and dark menu bars and when highlighted). The dial is punched out of
/// the flame with `destinationOut`.
pub fn menu_bar_image(remaining: Option<f64>, edge: u32) -> Canvas {
    menu_bar_image_in(remaining, edge, RgbColor::new(0.0, 0.0, 0.0))
}

/// The same mark, drawn in `ink`.
///
/// The colour matters because macOS is the only platform that recolours it: the
/// image goes over as a *template*, and the system tints it for the menu bar. Every
/// other platform shows these pixels as drawn, so black is invisible on a dark
/// Windows taskbar or a dark Linux panel — which is what "black instead of white"
/// was on Windows. Those ask for white.
pub fn menu_bar_image_in(remaining: Option<f64>, edge: u32, ink: RgbColor) -> Canvas {
    supersampled(edge, |large| {
        let mut canvas = Canvas::new(large).zoomed(MENU_BAR_ZOOM, MENU_BAR_INK_CENTRE);
        let angle = StatusIcon::needle_angle(remaining);

        canvas.fill_shape(in_flame, ink, ink, (6.0, 60.0));
        // Punch the dial core out.
        clear_oval(&mut canvas, DIAL_CENTER, DIAL_RADIUS);
        canvas.stroke_line(PIVOT, needle_tip(angle), NEEDLE_WIDTH, ink);
        canvas.fill_oval(PIVOT, PIVOT_RADIUS, ink);
        canvas
    })
}

/// How much larger a small mark is drawn before being reduced. Four is enough
/// for the edges to read as smooth at the 18pt the menu bar draws.
const SUPERSAMPLE: u32 = 4;

/// Below this size the mark is drawn at [`SUPERSAMPLE`]x and box-downsampled.
/// Above it the aliasing is already invisible and the extra pixels are not worth
/// the time — `icon-gen` renders at 1024.
const SUPERSAMPLE_BELOW: u32 = 128;

/// Draws a mark at 4x and box-downsamples it.
///
/// Every primitive here — `fill_oval`, `clear_oval`, `stroke_line` — tests a
/// point against an edge and writes full alpha or nothing, so their edges are
/// hard. That is invisible at 256px and obvious at 18: the dial's punched hole
/// and the needle come out visibly jagged, which reads as artifacting in the
/// menu bar. Supersampling gets antialiased edges without giving every primitive
/// a coverage calculation.
fn supersampled(edge: u32, draw: impl Fn(u32) -> Canvas) -> Canvas {
    if edge >= SUPERSAMPLE_BELOW || edge == 0 {
        return draw(edge);
    }
    let large = draw(edge * SUPERSAMPLE);
    let mut out = Canvas::new(edge);
    let samples = (SUPERSAMPLE * SUPERSAMPLE) as f64;
    for y in 0..edge {
        for x in 0..edge {
            let mut weighted = [0.0_f64; 3];
            let mut alpha_sum = 0.0_f64;
            for sy in 0..SUPERSAMPLE {
                for sx in 0..SUPERSAMPLE {
                    let lx = x * SUPERSAMPLE + sx;
                    let ly = y * SUPERSAMPLE + sy;
                    let index = ((ly * large.size + lx) * 4) as usize;
                    let alpha = large.pixels[index + 3] as f64 / 255.0;
                    for (channel, weight) in weighted.iter_mut().enumerate() {
                        *weight += large.pixels[index + channel] as f64 / 255.0 * alpha;
                    }
                    alpha_sum += alpha;
                }
            }
            let index = ((y * edge + x) * 4) as usize;
            // Averaged in premultiplied space and then unpremultiplied: averaging
            // straight colour across transparent pixels would drag every edge
            // toward black, which is its own kind of border.
            if alpha_sum > 0.0 {
                for (channel, weight) in weighted.iter().enumerate() {
                    out.pixels[index + channel] =
                        ((weight / alpha_sum) * 255.0).round().clamp(0.0, 255.0) as u8;
                }
            }
            out.pixels[index + 3] = ((alpha_sum / samples) * 255.0).round().clamp(0.0, 255.0) as u8;
        }
    }
    out
}

/// The rest pose the old Swift app's shipped `AppIcon.icns` was drawn at.
///
/// That icns — the artifact users actually saw — predates the Sep-2026 refactor
/// that moved the severity ramp into core, so it is **amber**, while the Swift
/// renderer's *current* code passes `nil`, which the ramp reads as 70% and paints
/// **green**. The amber pose is what shipped, so it is what the app icon defaults
/// to here. Change to `None` to follow the renderer's code instead.
pub const SHIPPED_ICON_POSE_REMAINING: f64 = 45.0;

/// Full-colour app icon: the flame on the dark plate, used for Dock,
/// notifications and About. The dark plate keeps the flame and cream needle
/// crisp on both dark banners and the light Dock grid.
pub fn app_icon(edge: u32) -> Canvas {
    app_icon_at(edge, Some(SHIPPED_ICON_POSE_REMAINING))
}

/// As [`app_icon`], with the pose the icon is drawn at.
pub fn app_icon_at(edge: u32, remaining: Option<f64>) -> Canvas {
    supersampled(edge, |edge| app_icon_plain(edge, remaining))
}

/// The app icon's geometry, drawn at whatever size it is handed.
fn app_icon_plain(edge: u32, remaining: Option<f64>) -> Canvas {
    let mut canvas = Canvas::new(edge);
    let angle = StatusIcon::needle_angle(remaining);
    let tint = StatusIcon::tint(remaining);

    canvas.fill_rounded_rect(1.5, 16.0, PLATE);
    // Light hairline border for definition on any surface.
    stroke_rounded_rect(
        &mut canvas,
        1.5,
        16.0,
        1.0,
        RgbColor::new(1.0, 1.0, 1.0),
        0.28,
    );

    // Flame filled with the severity gradient, clipped to its shape.
    canvas.fill_shape(in_flame, tint.top, tint.bottom, (6.0, 60.0));
    // Dial core — dark, with a faint rim so it reads on the dark plate.
    canvas.fill_oval(DIAL_CENTER, DIAL_RADIUS, DIAL_CORE);
    canvas.stroke_oval(
        DIAL_CENTER,
        DIAL_RADIUS,
        0.8,
        RgbColor::new(1.0, 1.0, 1.0),
        0.18,
    );
    canvas.stroke_line(PIVOT, needle_tip(angle), NEEDLE_WIDTH, CREAM);
    canvas.fill_oval(PIVOT, PIVOT_RADIUS, CREAM);
    canvas
}

impl Canvas {
    /// PNG bytes, for the window and the bundler.
    pub fn to_png(&self) -> Vec<u8> {
        let mut buffer = Vec::new();
        {
            let mut encoder = png::Encoder::new(&mut buffer, self.size, self.size);
            encoder.set_color(png::ColorType::Rgba);
            encoder.set_depth(png::BitDepth::Eight);
            let mut writer = encoder.write_header().expect("png header");
            writer.write_image_data(&self.pixels).expect("png pixels");
            writer.finish().expect("png finish");
        }
        buffer
    }

    /// `data:` URL, so the frontend can show the mark without a file path.
    /// The icons live in `src-tauri/icons`, which is not under the served
    /// `ui/app`, so a relative `<img src>` would 404 on every platform.
    pub fn to_data_url(&self) -> String {
        format!("data:image/png;base64,{}", base64_encode(&self.to_png()))
    }
}

fn base64_encode(bytes: &[u8]) -> String {
    const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for chunk in bytes.chunks(3) {
        let b = [
            chunk[0],
            *chunk.get(1).unwrap_or(&0),
            *chunk.get(2).unwrap_or(&0),
        ];
        let triple = ((b[0] as u32) << 16) | ((b[1] as u32) << 8) | b[2] as u32;
        out.push(ALPHABET[(triple >> 18) as usize & 63] as char);
        out.push(ALPHABET[(triple >> 12) as usize & 63] as char);
        out.push(if chunk.len() > 1 {
            ALPHABET[(triple >> 6) as usize & 63] as char
        } else {
            '='
        });
        out.push(if chunk.len() > 2 {
            ALPHABET[triple as usize & 63] as char
        } else {
            '='
        });
    }
    out
}

fn clear_oval(canvas: &mut Canvas, center: [f64; 2], radius: f64) {
    let r2 = radius * radius;
    for y in 0..canvas.size as i64 {
        for x in 0..canvas.size as i64 {
            let (px, py) = canvas.design_point(x, y);
            let dx = px - center[0];
            let dy = py - center[1];
            if dx * dx + dy * dy <= r2 {
                let index = ((y as u32 * canvas.size + x as u32) * 4) as usize;
                canvas.pixels[index] = 0;
                canvas.pixels[index + 1] = 0;
                canvas.pixels[index + 2] = 0;
                canvas.pixels[index + 3] = 0;
            }
        }
    }
}

fn stroke_rounded_rect(
    canvas: &mut Canvas,
    inset: f64,
    radius: f64,
    width: f64,
    color: RgbColor,
    alpha: f64,
) {
    // Centred on the path, the way `NSBezierPath.stroke()` is: half the width
    // inside the edge, half outside.
    //
    // This used to ink only the region *outside* the path. That halved the
    // hairline and pushed it off the plate entirely, which at taskbar sizes read
    // as a faint smear along the straight edges and as nothing at all on the
    // corners — there the boundary curves away, so the outward crescent's
    // coverage rounds to zero. Hence "the border is on the edges but not the
    // corners".
    let (lo, hi) = (inset, 72.0 - inset);
    let centre = (lo + hi) / 2.0;
    let half_extent = (hi - lo) / 2.0;
    let half = width / 2.0;
    for y in 0..canvas.size as i64 {
        for x in 0..canvas.size as i64 {
            let (px, py) = canvas.design_point(x, y);
            // Signed distance to the rounded-rect boundary: negative inside,
            // positive outside, and `abs()` is the distance to the edge. The
            // straight runs and the corner arcs fall out of the same expression,
            // which is the point — they previously did not.
            let qx = (px - centre).abs() - (half_extent - radius);
            let qy = (py - centre).abs() - (half_extent - radius);
            let outside = (qx.max(0.0).powi(2) + qy.max(0.0).powi(2)).sqrt();
            let signed = outside + qx.max(qy).min(0.0) - radius;
            if signed.abs() <= half {
                canvas.blend(x, y, color, alpha);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The flame outline encloses its middle and excludes the corners.
    #[test]
    fn flame_shape_is_sane() {
        assert!(in_flame(36.0, 40.0), "centre of the flame");
        assert!(!in_flame(4.0, 4.0), "top-left corner is outside");
        assert!(!in_flame(68.0, 68.0), "bottom-right corner is outside");
    }

    /// The needle points down-right at 60° and up at 0°, matching Swift.
    #[test]
    fn needle_tip_follows_angle() {
        let at_zero = needle_tip(0.0);
        assert!((at_zero[0] - PIVOT[0]).abs() < 0.01, "0° is straight up");
        assert!((at_zero[1] - (PIVOT[1] - NEEDLE_LENGTH)).abs() < 0.01);

        let at_sixty = needle_tip(60.0);
        assert!(at_sixty[0] > PIVOT[0], "60° leans right");
        assert!(
            at_sixty[1] > PIVOT[1] - NEEDLE_LENGTH,
            "and is shorter than full length"
        );
    }

    /// The mark is drawn in the ink it is given.
    ///
    /// Worth pinning because macOS is the one platform that never shows these
    /// pixels as written — it tints the template — so a wrong choice here is
    /// invisible on the machine the code is written on, and shows up only on
    /// Windows and Linux.
    #[test]
    fn the_mark_is_drawn_in_the_requested_ink() {
        for ink in [RgbColor::new(0.0, 0.0, 0.0), RgbColor::new(1.0, 1.0, 1.0)] {
            let canvas = menu_bar_image_in(Some(70.0), 36, ink);
            let mut saw_opaque = false;
            for chunk in canvas.pixels.chunks_exact(4) {
                if chunk[3] > 200 {
                    saw_opaque = true;
                    let want = (ink.red * 255.0).round() as u8;
                    assert!(
                        (chunk[0] as i16 - want as i16).abs() <= 1,
                        "expected ink {want}, got {:?}",
                        &chunk[0..3]
                    );
                }
            }
            assert!(saw_opaque, "something was actually drawn");
        }
    }

    /// The menu-bar image is monochrome with alpha, as a template must be.
    #[test]
    fn menu_bar_image_is_monochrome() {
        let canvas = menu_bar_image(Some(70.0), 36);
        let mut saw_opaque = false;
        for chunk in canvas.pixels.chunks_exact(4) {
            if chunk[3] > 200 {
                saw_opaque = true;
                assert!(
                    chunk[0] == chunk[1] && chunk[1] == chunk[2],
                    "template pixels are grey, got {:?}",
                    &chunk[0..3]
                );
            }
        }
        assert!(saw_opaque, "something was actually drawn");
    }

    /// The ink's vertical extent, for the framing tests.
    fn ink_rows(canvas: &Canvas) -> (u32, u32) {
        let (mut top, mut bottom) = (canvas.size, 0);
        for y in 0..canvas.size {
            for x in 0..canvas.size {
                if canvas.pixels[((y * canvas.size + x) * 4 + 3) as usize] > 8 {
                    top = top.min(y);
                    bottom = bottom.max(y);
                }
            }
        }
        (top, bottom)
    }

    /// The mark has to fill its canvas.
    ///
    /// `tray-icon` scales the whole canvas to a fixed 18pt, so padding in the
    /// design space is not margin in the menu bar, it is *lost size*. The flame
    /// inked 74% of the height and drew at 13.4pt, which is visibly small; the
    /// zoom brings it to ~89% and 16pt.
    #[test]
    fn the_menu_bar_mark_fills_its_canvas() {
        let edge = 128;
        let canvas = menu_bar_image(Some(84.0), edge);
        let (top, bottom) = ink_rows(&canvas);
        let height = bottom - top + 1;

        assert!(
            height as f64 / edge as f64 >= 0.85,
            "the mark inked {:.0}% of the canvas, so it draws at {:.1}pt",
            height as f64 / edge as f64 * 100.0,
            18.0 * height as f64 / edge as f64
        );
        // Not clipped by the canvas it is drawn into.
        assert!(top > 0, "the flame tip is flush against the top edge");
        assert!(
            bottom < edge - 1,
            "the flame base is flush against the bottom"
        );
        // And centred: the flame's ink sits above the design centre, so zooming
        // about the canvas instead of the ink would leave it riding high.
        let above = top;
        let below = edge - 1 - bottom;
        assert!(
            above.abs_diff(below) <= 1,
            "not centred: {above} above, {below} below"
        );
    }

    /// The app icon has its own framing: the plate is meant to reach its edges,
    /// and must not inherit the menu-bar zoom — which would push it past them.
    #[test]
    fn the_app_icon_keeps_its_own_framing() {
        let edge = 128;
        let canvas = app_icon_at(edge, Some(84.0));
        let (top, bottom) = ink_rows(&canvas);
        let filled = (bottom - top + 1) as f64 / edge as f64;

        assert!(filled > 0.9, "the plate reaches its edges, got {filled:.2}");
        assert!(
            top > 0 && bottom < edge - 1,
            "and stays inside them: rows {top}..{bottom} of {edge}"
        );
    }

    /// The plate's border straddles the edge, straight runs and corners alike.
    ///
    /// It used to be inked only *outside* the path, so it was half the intended
    /// weight and, on the corner arcs, rounded away to nothing: the border was
    /// visible along the edges and missing at the corners, which is what was
    /// reported on the Windows taskbar icon.
    ///
    /// 256 is deliberate — above `SUPERSAMPLE_BELOW`, so what is measured is the
    /// geometry rather than the downsampler. The band is only one design unit
    /// wide, so each probe takes the brightest pixel in a small window: a single
    /// pixel's centre can miss a half-unit band by rounding alone.
    #[test]
    fn the_plate_border_straddles_the_edge() {
        let canvas = app_icon(256);
        let size = canvas.size;
        let scale = size as f64 / 72.0;
        let window_max = |px: f64, py: f64, span: f64| -> u8 {
            let x0 = ((px - span) * scale).floor().clamp(0.0, size as f64 - 1.0) as u32;
            let x1 = ((px + span) * scale).ceil().clamp(0.0, size as f64 - 1.0) as u32;
            let y0 = ((py - span) * scale).floor().clamp(0.0, size as f64 - 1.0) as u32;
            let y1 = ((py + span) * scale).ceil().clamp(0.0, size as f64 - 1.0) as u32;
            let mut best = 0u8;
            for y in y0..=y1 {
                for x in x0..=x1 {
                    // Premultiplied RGBA, and the plate is opaque, so the red
                    // channel alone says whether the white hairline is there.
                    best = best.max(canvas.pixels[((y * size + x) * 4) as usize]);
                }
            }
            best
        };
        let pixel = |px: f64, py: f64| -> u8 {
            let x = (px * scale) as u32;
            let y = (py * scale) as u32;
            canvas.pixels[((y * size + x) * 4) as usize]
        };

        let (inset, radius) = (1.5, 16.0);
        // Two units inside the boundary is clear of the one-unit band.
        let straight_reference = pixel(inset + 2.0, 36.0);
        let diagonal = radius / 2.0_f64.sqrt();
        let corner_reference = pixel(
            inset + radius - diagonal + 2.0,
            inset + radius - diagonal + 2.0,
        );

        let straight = window_max(inset, 36.0, 1.0);
        let corner = window_max(inset + radius - diagonal, inset + radius - diagonal, 1.2);

        assert!(
            straight > straight_reference + 20,
            "no hairline across the straight edge: {straight} vs plate {straight_reference}"
        );
        assert!(
            corner > corner_reference + 20,
            "no hairline across the corner arc: {corner} vs plate {corner_reference}"
        );
    }

    /// A fully-used window reddens the flame; a healthy one greens it.
    #[test]
    fn app_icon_tint_tracks_remaining() {
        let healthy = app_icon_at(64, Some(95.0));
        let spent = app_icon_at(64, Some(5.0));
        assert!(!healthy.pixels.is_empty());
        assert_ne!(healthy.pixels, spent.pixels, "tint must reach the pixels");
        assert_eq!(StatusIcon::tint(Some(95.0)).top.to_hex(), "#8fe07a");
        // The 20% and 0% stops are the same red, so 5% lands on it exactly.
        assert_eq!(StatusIcon::tint(Some(5.0)).top.to_hex(), "#ff8a5c");
        assert_eq!(StatusIcon::tint(Some(5.0)).bottom.to_hex(), "#e64019");
    }

    /// The flame fill lands inside the outline, not outside it.
    #[test]
    fn flame_fill_is_inside_the_outline() {
        fn alpha_at(canvas: &Canvas, x: u32, y: u32) -> u8 {
            let index = ((y * canvas.size + x) * 4) as usize;
            canvas.pixels[index + 3]
        }

        let mut canvas = Canvas::new(72);
        let red = RgbColor::new(1.0, 0.0, 0.0);
        canvas.fill_shape(in_flame, red, red, (6.0, 60.0));
        // The top-left corner must stay empty: an inverted fill would flood it.
        assert_eq!(alpha_at(&canvas, 1, 1), 0, "corner must be transparent");
        // The flame body must be painted.
        assert_eq!(alpha_at(&canvas, 24, 36), 255, "flame body must be opaque");
    }

    /// The app icon defaults to the pose the shipped icns was drawn at.
    #[test]
    fn shipped_icon_pose_is_amber() {
        let tint = StatusIcon::tint(Some(SHIPPED_ICON_POSE_REMAINING));
        assert_eq!(tint.top.to_hex(), "#ffc24b", "the shipped flame is amber");
    }
}
