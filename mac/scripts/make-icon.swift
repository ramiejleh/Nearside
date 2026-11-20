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

    // The tile: deep green to teal, with the system's soft drop shadow.
    let tile = NSBezierPath(roundedRect: r(100, 100, 824, 824), xRadius: 185 * s, yRadius: 185 * s)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = .black.withAlphaComponent(0.3)
    shadow.shadowOffset = NSSize(width: 0, height: -10 * s)
    shadow.shadowBlurRadius = 22 * s
    shadow.set()
    NSColor.black.setFill()
    tile.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.saveGraphicsState()
    tile.addClip()
    NSGradient(colors: [NSColor(red: 0.13, green: 0.70, blue: 0.47, alpha: 1),
                        NSColor(red: 0.04, green: 0.36, blue: 0.52, alpha: 1)])!.draw(in: r(100, 100, 824, 824), angle: -60)
    // A faint sheen across the top.
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.16), NSColor.white.withAlphaComponent(0)])!
        .draw(in: r(100, 560, 824, 364), angle: -90)

    let white = NSColor.white
    // The Mac: a display with a stand, at the back right.
    let screen = NSBezierPath(roundedRect: r(330, 400, 470, 330), xRadius: 34 * s, yRadius: 34 * s)
    screen.lineWidth = 34 * s
    white.withAlphaComponent(0.92).setStroke()
    screen.stroke()
    let stand = NSBezierPath()
    stand.move(to: NSPoint(x: 565 * s, y: 383 * s)); stand.line(to: NSPoint(x: 565 * s, y: 318 * s))
    stand.move(to: NSPoint(x: 470 * s, y: 300 * s)); stand.line(to: NSPoint(x: 660 * s, y: 300 * s))
    stand.lineWidth = 34 * s
    stand.lineCapStyle = .round
    stand.stroke()

    // An app window on the Mac's screen, as if carried over from the phone.
    white.withAlphaComponent(0.92).setFill()
    NSBezierPath(roundedRect: r(560, 470, 150, 196), xRadius: 18 * s, yRadius: 18 * s).fill()

    // The phone, in front at the left: solid, with its screen cut out.
    let phoneRect = r(215, 250, 250, 450)
    NSGraphicsContext.saveGraphicsState()
    let lift = NSShadow()
    lift.shadowColor = NSColor.black.withAlphaComponent(0.28)
    lift.shadowOffset = NSSize(width: 0, height: -8 * s)
    lift.shadowBlurRadius = 24 * s
    lift.set()
    white.setFill()
    NSBezierPath(roundedRect: phoneRect, xRadius: 46 * s, yRadius: 46 * s).fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(colors: [NSColor(red: 0.10, green: 0.58, blue: 0.48, alpha: 1),
                        NSColor(red: 0.05, green: 0.40, blue: 0.53, alpha: 1)])!
        .draw(in: NSBezierPath(roundedRect: r(240, 290, 200, 380), xRadius: 26 * s, yRadius: 26 * s), angle: -60)
    // The same app on the phone's screen, and the camera.
    white.withAlphaComponent(0.92).setFill()
    NSBezierPath(roundedRect: r(285, 395, 110, 144), xRadius: 14 * s, yRadius: 14 * s).fill()
    NSBezierPath(ovalIn: r(329, 640, 22, 22)).fill()

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
