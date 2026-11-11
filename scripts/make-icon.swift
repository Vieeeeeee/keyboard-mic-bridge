// Renders resources/AppIcon.icns: a white Fn keycap with a microphone on a deep ink tile.
// Run: swift scripts/make-icon.swift  (needs macOS with SF Symbols)
import AppKit

func render(_ size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let u = size / 1024

    // Tile: macOS icon grid (824pt body, 100pt margin), soft drop shadow.
    let tile = NSRect(x: 100 * u, y: 100 * u, width: 824 * u, height: 824 * u)
    let tilePath = NSBezierPath(roundedRect: tile, xRadius: 185 * u, yRadius: 185 * u)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowOffset = NSSize(width: 0, height: -10 * u); shadow.shadowBlurRadius = 24 * u; shadow.set()
    NSColor(srgbRed: 0.13, green: 0.14, blue: 0.17, alpha: 1).setFill(); tilePath.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: NSColor(srgbRed: 0.24, green: 0.26, blue: 0.32, alpha: 1),
               ending: NSColor(srgbRed: 0.09, green: 0.10, blue: 0.13, alpha: 1))!.draw(in: tilePath, angle: -90)

    // Keycap: raised base + lighter top face.
    let cap = NSRect(x: 252 * u, y: 262 * u, width: 520 * u, height: 520 * u)
    let base = NSBezierPath(roundedRect: cap.offsetBy(dx: 0, dy: -22 * u), xRadius: 96 * u, yRadius: 96 * u)
    NSGraphicsContext.saveGraphicsState()
    let capShadow = NSShadow(); capShadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
    capShadow.shadowOffset = NSSize(width: 0, height: -18 * u); capShadow.shadowBlurRadius = 36 * u; capShadow.set()
    NSColor(srgbRed: 0.72, green: 0.73, blue: 0.77, alpha: 1).setFill(); base.fill()
    NSGraphicsContext.restoreGraphicsState()
    let face = NSBezierPath(roundedRect: cap, xRadius: 96 * u, yRadius: 96 * u)
    NSGradient(starting: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),
               ending: NSColor(srgbRed: 0.90, green: 0.91, blue: 0.93, alpha: 1))!.draw(in: face, angle: -90)

    let ink = NSColor(srgbRed: 0.12, green: 0.13, blue: 0.16, alpha: 1)
    // "fn" legend, top-left like the real key.
    let fn = NSAttributedString(string: "fn", attributes: [.font: NSFont.systemFont(ofSize: 74 * u, weight: .medium),
                                                           .foregroundColor: ink.withAlphaComponent(0.55)])
    fn.draw(at: NSPoint(x: cap.minX + 62 * u, y: cap.maxY - 140 * u))

    // Microphone in the accent colour.
    let config = NSImage.SymbolConfiguration(pointSize: 250 * u, weight: .semibold)
        .applying(.init(paletteColors: [NSColor(srgbRed: 1.0, green: 0.36, blue: 0.24, alpha: 1)]))
    let mic = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: nil)!.withSymbolConfiguration(config)!
    let ms = mic.size
    mic.draw(in: NSRect(x: cap.midX - ms.width / 2, y: cap.midY - ms.height / 2 - 36 * u, width: ms.width, height: ms.height))

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let set = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: set)
try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try render(CGFloat(base * scale)).representation(using: .png, properties: [:])!.write(to: set.appendingPathComponent(name))
    }
}
try render(1024).representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent("resources/AppIcon-preview.png"))
let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", set.path, "-o", root.appendingPathComponent("resources/AppIcon.icns").path]
try p.run(); p.waitUntilExit()
print(p.terminationStatus == 0 ? "wrote resources/AppIcon.icns" : "iconutil failed")
