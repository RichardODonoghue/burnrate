// Generates Resources/AppIcon.icns — the G2 "Dial Core" mark: bare amber
// flame (no plate), dark dial core knocked in, cream needle. Brand pose.
// Run: swift scripts/make_icon.swift
import AppKit

// 72-unit design space (y-down), from the G2 sheet.
let flamePath: NSBezierPath = {
    let p = NSBezierPath()
    p.move(to: NSPoint(x: 36, y: 6))
    p.curve(to: NSPoint(x: 19.5, y: 27), controlPoint1: NSPoint(x: 33, y: 14), controlPoint2: NSPoint(x: 24, y: 20))
    p.curve(to: NSPoint(x: 15.5, y: 41), controlPoint1: NSPoint(x: 16.5, y: 32), controlPoint2: NSPoint(x: 15.5, y: 36.5))
    p.curve(to: NSPoint(x: 36, y: 60), controlPoint1: NSPoint(x: 15.5, y: 52), controlPoint2: NSPoint(x: 24.5, y: 60))
    p.curve(to: NSPoint(x: 56.5, y: 41), controlPoint1: NSPoint(x: 47.5, y: 60), controlPoint2: NSPoint(x: 56.5, y: 52))
    p.curve(to: NSPoint(x: 52.5, y: 27), controlPoint1: NSPoint(x: 56.5, y: 36.5), controlPoint2: NSPoint(x: 55.5, y: 32))
    p.curve(to: NSPoint(x: 36, y: 6), controlPoint1: NSPoint(x: 48, y: 20), controlPoint2: NSPoint(x: 39, y: 14))
    p.close()
    return p
}()
let dialCenter = NSPoint(x: 36, y: 42)
let dialRadius: CGFloat = 10.5
let pivot = NSPoint(x: 36, y: 46)
let pivotRadius: CGFloat = 2.2
let needleLength: CGFloat = 22
let needleWidth: CGFloat = 2.6
let restAngle: Double = 18 // 70% remaining

func drawAppIcon(size: CGFloat) -> NSImage {
    let scale = size / 72
    return NSImage(size: NSSize(width: size, height: size), flipped: true) { _ in
        let context = NSGraphicsContext.current!.cgContext
        context.scaleBy(x: scale, y: scale)

        // Bare flame with the amber-orange brand gradient (no plate).
        context.saveGState()
        flamePath.addClip()
        NSGradient(starting: NSColor(calibratedRed: 0xFF / 255, green: 0xC2 / 255, blue: 0x4B / 255, alpha: 1),
                   ending: NSColor(calibratedRed: 0xFF / 255, green: 0x7A / 255, blue: 0x3D / 255, alpha: 1))?
            .draw(in: NSRect(x: 15.5, y: 6, width: 41, height: 54), angle: 90)
        context.restoreGState()

        // Dark dial core knocked into the flame.
        NSColor(calibratedRed: 0x20 / 255, green: 0x0A / 255, blue: 0x02 / 255, alpha: 0.88).setFill()
        NSBezierPath(ovalIn: NSRect(x: dialCenter.x - dialRadius, y: dialCenter.y - dialRadius,
                                    width: dialRadius * 2, height: dialRadius * 2)).fill()

        // Cream needle + pivot (18° from vertical).
        let radians = restAngle * .pi / 180
        NSColor(calibratedRed: 0xFF / 255, green: 0xF6 / 255, blue: 0xEA / 255, alpha: 1).setStroke()
        let needle = NSBezierPath()
        needle.move(to: pivot)
        needle.line(to: NSPoint(x: pivot.x + needleLength * CGFloat(sin(radians)),
                                y: pivot.y - needleLength * CGFloat(cos(radians))))
        needle.lineWidth = needleWidth
        needle.lineCapStyle = .round
        needle.stroke()
        NSColor(calibratedRed: 0xFF / 255, green: 0xF6 / 255, blue: 0xEA / 255, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: pivot.x - pivotRadius, y: pivot.y - pivotRadius,
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

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let iconsetURL = root.appendingPathComponent("build/AppIcon.iconset")
let resourcesURL = root.appendingPathComponent("Resources")

try? FileManager.default.removeItem(at: iconsetURL)
try FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)
for (pixels, suffix) in [(16, "16x16"), (32, "16x16@2x"), (32, "32x32"), (64, "32x32@2x"),
                         (128, "128x128"), (256, "128x128@2x"), (256, "256x256"),
                         (512, "256x256@2x"), (512, "512x512"), (1024, "512x512@2x")] {
    try writePNG(drawAppIcon(size: CGFloat(pixels)), pixels: pixels, to: iconsetURL, name: "icon_" + suffix + ".png")
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
