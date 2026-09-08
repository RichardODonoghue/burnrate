// Generates Resources/AppIcon.icns from the G2 "Dial Core" mark.
// Compiled together with Sources/BurnRate/Icons.swift so the icns and the
// runtime renderer share one geometry source:
//   swiftc Sources/BurnRate/Icons.swift scripts/make_icon.swift -o build/makeicon && ./build/makeicon
import AppKit

@main
struct MakeIcon {
    static func main() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let iconsetURL = root.appendingPathComponent("build/AppIcon.iconset")
        let resourcesURL = root.appendingPathComponent("Resources")

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
            let image = AppIconRenderer.appIconImage(size: CGFloat(pixels))
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
    }
}
