#!/usr/bin/env swift
// Draws the Windows app's icons (run on a Mac: swift windows/scripts/make-icons.swift), from the
// logo's geometry in mac/Sources/Nearside/Logo.swift:
//   App/Assets/Nearside.ico               the app icon: the graphite tile with the white mark
//   App/Assets/Logo.png                   that tile edge to edge, for the app's own windows
//   App/Assets/tray-{dark,light}{,-off}.ico  the tray mark, white for dark taskbars and black for
//                                            light ones; "-off" is outlined (not connected)
import AppKit

let shapes: [(rect: NSRect, radius: CGFloat)] = [
    (NSRect(x: 247, y: 340, width: 180, height: 330), 40),
    (NSRect(x: 467, y: 410, width: 310, height: 220), 34),
    (NSRect(x: 572, y: 355, width: 100, height: 30), 15),
]
let markBounds = NSRect(x: 247, y: 340, width: 530, height: 330)

func png(_ size: Int, _ draw: (CGFloat) -> Void) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw(CGFloat(size))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

func tile(_ size: CGFloat) { tile(size, inset: size * 0.04) } // Windows icons keep a small margin

func tile(_ size: CGFloat, inset: CGFloat) {
    let side = size - 2 * inset
    let s = side / 824
    NSColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: inset, y: inset, width: side, height: side), xRadius: 185 * s, yRadius: 185 * s).fill()
    NSColor.white.setFill()
    for shape in shapes {
        let r = NSRect(x: inset + (shape.rect.minX - 100) * s, y: inset + (shape.rect.minY - 100) * s,
                       width: shape.rect.width * s, height: shape.rect.height * s)
        NSBezierPath(roundedRect: r, xRadius: shape.radius * s, yRadius: shape.radius * s).fill()
    }
}

func mark(_ size: CGFloat, color: NSColor, outlined: Bool) {
    let s = size / markBounds.width // as wide as the icon, centred vertically
    let top = (size - markBounds.height * s) / 2
    color.set()
    for shape in shapes {
        var r = NSRect(x: (shape.rect.minX - markBounds.minX) * s, y: top + (shape.rect.minY - markBounds.minY) * s,
                       width: shape.rect.width * s, height: shape.rect.height * s)
        let line = max(1, size / 16)
        let hollow = outlined && shape.rect.height > 100
        if hollow { r = r.insetBy(dx: line / 2, dy: line / 2) }
        let path = NSBezierPath(roundedRect: r, xRadius: shape.radius * s, yRadius: shape.radius * s)
        if hollow {
            path.lineWidth = line
            path.stroke()
        } else {
            path.fill()
        }
    }
}

/// An .ico holding a PNG per size.
func ico(_ images: [(Int, Data)]) -> Data {
    var data = Data()
    func u16(_ v: Int) { data.append(contentsOf: [UInt8(v & 0xFF), UInt8(v >> 8)]) }
    func u32(_ v: Int) { u16(v & 0xFFFF); u16(v >> 16) }
    u16(0); u16(1); u16(images.count)
    var offset = 6 + 16 * images.count
    for (size, png) in images {
        data.append(contentsOf: [UInt8(size >= 256 ? 0 : size), UInt8(size >= 256 ? 0 : size), 0, 0])
        u16(1); u16(32); u32(png.count); u32(offset)
        offset += png.count
    }
    for (_, png) in images { data.append(png) }
    return data
}

let out = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
    .appendingPathComponent("../App/Assets").standardized
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
try ico([16, 20, 24, 32, 40, 48, 64, 256].map { ($0, png($0, tile)) }).write(to: out.appendingPathComponent("Nearside.ico"))
try png(256) { tile($0, inset: 0) }.write(to: out.appendingPathComponent("Logo.png"))
for (name, color) in [("dark", NSColor.white), ("light", NSColor.black)] {
    for outlined in [false, true] {
        let images = [16, 20, 24, 32, 40, 48].map { ($0, png($0) { mark($0, color: color, outlined: outlined) }) }
        try ico(images).write(to: out.appendingPathComponent("tray-\(name)\(outlined ? "-off" : "").ico"))
    }
}
print("wrote icons to \(out.path)")
