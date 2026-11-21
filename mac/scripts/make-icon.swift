// Draws Nearside's app icon (macOS icon grid: an 824 pt rounded square on a 1024 canvas) and
// writes an .icns. Run from the repo:  swift mac/scripts/make-icon.swift mac/Resources/AppIcon.icns
import AppKit

let out = CommandLine.arguments.dropFirst().first ?? "AppIcon.icns"

func draw(_ size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024
    func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect { NSRect(x: x * s, y: y * s, width: w * s, height: h * s) }

    // Flat and minimal: a solid graphite tile, and the phone beside the Mac's screen in white,
    // close together (the "near side"). No gradients, no shadows.
    NSColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1).setFill()
    NSBezierPath(roundedRect: r(100, 100, 824, 824), xRadius: 185 * s, yRadius: 185 * s).fill()
    NSGraphicsContext.saveGraphicsState()
    NSColor.white.setFill()
    // The phone.
    NSBezierPath(roundedRect: r(247, 340, 180, 330), xRadius: 40 * s, yRadius: 40 * s).fill()
    // The Mac's screen and its stand.
    NSBezierPath(roundedRect: r(467, 410, 310, 220), xRadius: 34 * s, yRadius: 34 * s).fill()
    NSBezierPath(roundedRect: r(572, 355, 100, 30), xRadius: 15 * s, yRadius: 15 * s).fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let set = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon-\(getpid()).iconset")
try? FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try! draw(CGFloat(base * scale)).representation(using: .png, properties: [:])!.write(to: set.appendingPathComponent(name))
    }
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", set.path, "-o", out]
try! p.run()
p.waitUntilExit()
try? draw(1024).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out).deletingPathExtension().appendingPathExtension("png"))
print(p.terminationStatus == 0 ? "wrote \(out)" : "iconutil failed")
