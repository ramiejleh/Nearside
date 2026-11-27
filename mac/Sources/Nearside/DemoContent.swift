import AppKit
import NearsideCore

/// Sample clips and photos for pictures of the panel (NEARSIDE_TEST_DEMO=1): made up and drawn
/// here, so no one's own content ever appears in the README or on the website.
enum DemoContent {
    static var clips: [ClipItem] {
        let now = Date()
        func clip(_ text: String, _ source: ClipItem.Source, _ minutes: Double) -> ClipItem {
            ClipItem(text: text, source: source, date: now.addingTimeInterval(-minutes * 60))
        }
        return [
            clip("Platform 4, the 09:12 to Aarhus", .android, 2),
            clip("https://example.com/recipes/lemon-pasta", .mac, 9),
            clip("Flat white, oat milk, no sugar", .android, 26),
            clip("Design review moved to 15:30, room Blue", .mac, 64),
            clip("Chapter nine for Thursday", .android, 180),
            clip("Order 4471-2290 ships on Monday", .android, 300),
        ]
    }

    /// Landscapes and two screenshots, drawn as JPEG thumbnails.
    static var photos: [(PhonePhoto, Data)] {
        let now = Date()
        let scenes: [(sky: (NSColor, NSColor), land: NSColor, sun: NSColor?, screenshot: Bool)] = [
            ((.init(red: 0.98, green: 0.62, blue: 0.38, alpha: 1), .init(red: 0.55, green: 0.33, blue: 0.62, alpha: 1)), .init(red: 0.2, green: 0.16, blue: 0.3, alpha: 1), .init(red: 1, green: 0.86, blue: 0.55, alpha: 1), false),
            ((.init(red: 0.45, green: 0.72, blue: 0.95, alpha: 1), .init(red: 0.82, green: 0.92, blue: 1, alpha: 1)), .init(red: 0.3, green: 0.58, blue: 0.36, alpha: 1), .init(red: 1, green: 0.97, blue: 0.8, alpha: 1), false),
            ((.init(red: 0.95, green: 0.95, blue: 0.97, alpha: 1), .init(red: 0.95, green: 0.95, blue: 0.97, alpha: 1)), .white, nil, true),
            ((.init(red: 0.1, green: 0.14, blue: 0.32, alpha: 1), .init(red: 0.32, green: 0.3, blue: 0.55, alpha: 1)), .init(red: 0.08, green: 0.1, blue: 0.2, alpha: 1), .init(red: 0.95, green: 0.95, blue: 0.85, alpha: 1), false),
            ((.init(red: 0.55, green: 0.8, blue: 0.85, alpha: 1), .init(red: 0.95, green: 0.88, blue: 0.7, alpha: 1)), .init(red: 0.9, green: 0.78, blue: 0.55, alpha: 1), nil, false),
            ((.init(red: 0.12, green: 0.12, blue: 0.14, alpha: 1), .init(red: 0.12, green: 0.12, blue: 0.14, alpha: 1)), .black, nil, true),
        ]
        return scenes.enumerated().map { i, scene in
            let name = scene.screenshot ? "Screenshot_demo_\(i).png" : "PXL_demo_\(i).jpg"
            let photo = PhonePhoto(id: Int64(9_000 + i), name: name, path: "/sdcard/DCIM/\(name)",
                                   date: now.addingTimeInterval(Double(-i) * 3_600), isScreenshot: scene.screenshot,
                                   width: 1080, height: 1080, size: 1)
            return (photo, thumbnail(scene.sky, scene.land, scene.sun, screenshot: scene.screenshot))
        }
    }

    private static func thumbnail(_ sky: (NSColor, NSColor), _ land: NSColor, _ sun: NSColor?, screenshot: Bool) -> Data {
        let size = 256
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let s = CGFloat(size)
        NSGradient(starting: sky.1, ending: sky.0)!.draw(in: NSRect(x: 0, y: 0, width: s, height: s), angle: 90)
        if screenshot {
            // A chat-like screen: bars of text in bubbles.
            let dark = sky.0.brightnessComponent < 0.5
            let bubble = dark ? NSColor(white: 0.25, alpha: 1) : NSColor(white: 0.86, alpha: 1)
            let accent = NSColor(red: 0.3, green: 0.55, blue: 0.95, alpha: 1)
            for (j, mine) in [false, true, false, true, false].enumerated() {
                let width = s * (mine ? 0.5 : 0.6)
                let rect = NSRect(x: mine ? s - width - 18 : 18, y: s - 46 - CGFloat(j) * 44, width: width, height: 32)
                (mine ? accent : bubble).setFill()
                NSBezierPath(roundedRect: rect, xRadius: 14, yRadius: 14).fill()
            }
        } else {
            if let sun {
                sun.setFill()
                NSBezierPath(ovalIn: NSRect(x: s * 0.58, y: s * 0.5, width: s * 0.22, height: s * 0.22)).fill()
            }
            land.withAlphaComponent(0.75).setFill()
            let far = NSBezierPath()
            far.move(to: NSPoint(x: 0, y: s * 0.42))
            far.curve(to: NSPoint(x: s, y: s * 0.38), controlPoint1: NSPoint(x: s * 0.3, y: s * 0.62), controlPoint2: NSPoint(x: s * 0.62, y: s * 0.3))
            far.line(to: NSPoint(x: s, y: 0)); far.line(to: .zero); far.close(); far.fill()
            land.setFill()
            let near = NSBezierPath()
            near.move(to: NSPoint(x: 0, y: s * 0.24))
            near.curve(to: NSPoint(x: s, y: s * 0.3), controlPoint1: NSPoint(x: s * 0.4, y: s * 0.12), controlPoint2: NSPoint(x: s * 0.7, y: s * 0.42))
            near.line(to: NSPoint(x: s, y: 0)); near.line(to: .zero); near.close(); near.fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) ?? Data()
    }
}
