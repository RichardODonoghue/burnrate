// Generates Resources/AppIcon.icns from the BurnRate mark (gauge dial +
// gradient flame on a dark rounded square). Run: swift scripts/make_icon.swift
import AppKit

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let iconsetURL = root.appendingPathComponent("build/AppIcon.iconset")
let resourcesURL = root.appendingPathComponent("Resources")

func drawAppIcon(size: CGFloat) -> NSImage {
    NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
        // Dark rounded-square background.
        let background = NSBezierPath(roundedRect: rect.insetBy(dx: rect.width * 0.02, dy: rect.height * 0.02),
                                      xRadius: rect.width * 0.22, yRadius: rect.width * 0.22)
        NSColor(calibratedWhite: 0.10, alpha: 1).setFill()
        background.fill()

        // Gradient flame rising, with a white gauge needle laid over it.
        let flameRect = NSRect(x: rect.midX - rect.width * 0.24,
                               y: rect.height * 0.22,
                               width: rect.width * 0.48,
                               height: rect.height * 0.68)
        guard let symbol = NSImage(systemSymbolName: "flame.fill",
                                   accessibilityDescription: "flame") else { return true }
        let scaled = symbol.withSymbolConfiguration(.init(pointSize: flameRect.height, weight: .bold)) ?? symbol
        let target = NSImage(size: flameRect.size, flipped: false) { _ in
            scaled.draw(in: NSRect(origin: .zero, size: flameRect.size), from: .zero, operation: .copy, fraction: 1)
            let gradient = NSGradient(starting: NSColor(calibratedRed: 1.0, green: 0.62, blue: 0.20, alpha: 1),
                                      ending: NSColor(calibratedRed: 0.90, green: 0.25, blue: 0.10, alpha: 1))
            NSGraphicsContext.current?.cgContext.setBlendMode(.sourceAtop)
            gradient?.draw(in: NSRect(origin: .zero, size: flameRect.size), angle: 90)
            NSGraphicsContext.current?.cgContext.setBlendMode(.normal)
            return true
        }
        target.draw(in: flameRect, from: .zero, operation: .sourceOver, fraction: 1)

        // Needle over the flame, tilted 18° from vertical.
        let angle = (90.0 - 18.0) * Double.pi / 180
        let base = NSPoint(x: rect.midX + rect.width * 0.01, y: rect.height * 0.20)
        let length = rect.height * 0.62
        let tip = NSPoint(x: base.x + length * CGFloat(cos(angle)), y: base.y + length * CGFloat(sin(angle)))
        NSColor(calibratedWhite: 0.96, alpha: 1).setStroke()
        let needle = NSBezierPath()
        needle.move(to: base)
        needle.line(to: tip)
        needle.lineWidth = rect.width * 0.05
        needle.lineCapStyle = .round
        needle.stroke()
        NSColor(calibratedWhite: 0.96, alpha: 1).setFill()
        let pivotRadius = rect.width * 0.045
        NSBezierPath(ovalIn: NSRect(x: base.x - pivotRadius, y: base.y - pivotRadius,
                                    width: pivotRadius * 2, height: pivotRadius * 2)).fill()
        return true
    }
}

func writePNG(_ image: NSImage, pixels: Int, to directory: URL, name: String) throws {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels),
               from: .zero, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    let data = rep.representation(using: .png, properties: [:])!
    try data.write(to: directory.appendingPathComponent(name))
}

try? FileManager.default.removeItem(at: iconsetURL)
try FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)
for (pixels, suffix) in [(16, "16x16"), (32, "16x16@2x"), (32, "32x32"), (64, "32x32@2x"),
                         (128, "128x128"), (256, "128x128@2x"), (256, "256x256"),
                         (512, "256x256@2x"), (512, "512x512"), (1024, "512x512@2x")] {
    let image = drawAppIcon(size: CGFloat(pixels))
    try writePNG(image, pixels: pixels, to: iconsetURL, name: "icon_" + suffix + ".png")
}
try? FileManager.default.removeItem(at: resourcesURL.appendingPathComponent("AppIcon.icns"))
try FileManager.default.createDirectory(at: resourcesURL, withIntermediateDirectories: true)
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconsetURL.path,
                     "-o", resourcesURL.appendingPathComponent("AppIcon.icns").path]
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else {
    FileHandle.standardError.write(Data("iconutil failed\n".utf8))
    exit(1)
}
print("written: \(resourcesURL.path)/AppIcon.icns")
