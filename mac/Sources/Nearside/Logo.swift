import AppKit
import SwiftUI

/// Nearside's logo, drawn in code so it's crisp at any size: a white phone beside a Mac's screen,
/// on a flat graphite tile. The same geometry as the app icon (mac/scripts/make-icon.swift, in its
/// 1024 grid) and the phone app's icon (android/.../res/drawable/ic_launcher_foreground.xml).
enum Logo {
    static let tileColor = NSColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1)

    /// The mark's shapes in the 1024 icon grid (y up): phone, screen, stand.
    private static let shapes: [(rect: NSRect, radius: CGFloat)] = [
        (NSRect(x: 247, y: 340, width: 180, height: 330), 40),
        (NSRect(x: 467, y: 410, width: 310, height: 220), 34),
        (NSRect(x: 572, y: 355, width: 100, height: 30), 15),
    ]
    /// The mark's bounds in that grid.
    private static let markBounds = NSRect(x: 247, y: 340, width: 530, height: 330)

    /// The tile with the mark, filling `size` (no transparent margin).
    static func tile(size: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let s = rect.width / 824 // the tile is 824 of the 1024 grid
            tileColor.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 185 * s, yRadius: 185 * s).fill()
            NSColor.white.setFill()
            for shape in shapes {
                let r = NSRect(x: (shape.rect.minX - 100) * s, y: (shape.rect.minY - 100) * s,
                               width: shape.rect.width * s, height: shape.rect.height * s)
                NSBezierPath(roundedRect: r, xRadius: shape.radius * s, yRadius: shape.radius * s).fill()
            }
            return true
        }
    }

    /// The mark alone as a menu-bar template image `height` points tall: solid, or outlined
    /// (not connected).
    static func menuBarMark(height: CGFloat, outlined: Bool) -> NSImage {
        let s = height / markBounds.height
        let size = NSSize(width: (markBounds.width * s).rounded(.up), height: height)
        let image = NSImage(size: size, flipped: false) { _ in
            NSColor.black.set()
            for shape in shapes {
                var r = NSRect(x: (shape.rect.minX - markBounds.minX) * s, y: (shape.rect.minY - markBounds.minY) * s,
                               width: shape.rect.width * s, height: shape.rect.height * s)
                let line: CGFloat = 1.3
                if outlined && shape.rect.height > 100 { r = r.insetBy(dx: line / 2, dy: line / 2) }
                let path = NSBezierPath(roundedRect: r, xRadius: shape.radius * s, yRadius: shape.radius * s)
                if outlined && shape.rect.height > 100 {
                    path.lineWidth = line
                    path.stroke()
                } else {
                    path.fill()
                }
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}

/// The logo tile as a SwiftUI view.
struct LogoTile: View {
    let size: CGFloat

    var body: some View {
        Image(nsImage: Logo.tile(size: size))
            .resizable()
            .frame(width: size, height: size)
            .accessibilityLabel("Nearside")
    }
}

/// The app's accent: the logo's graphite. Near-black in light mode, a mid graphite in dark mode
/// (near-black would vanish there); `onAccent` is the text drawn on it.
enum Theme {
    static let nsAccent = NSColor(name: "NearsideAccent") { appearance in
        isDark(appearance) ? NSColor(red: 0.62, green: 0.62, blue: 0.65, alpha: 1) : Logo.tileColor
    }
    static let nsOnAccent = NSColor(name: "NearsideOnAccent") { appearance in
        isDark(appearance) ? NSColor(red: 0.08, green: 0.08, blue: 0.09, alpha: 1) : .white
    }
    static let accent = Color(nsColor: nsAccent)
    static let onAccent = Color(nsColor: nsOnAccent)

    private static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.darkAqua, .aqua, .vibrantDark, .vibrantLight]).map { $0 == .darkAqua || $0 == .vibrantDark } ?? false
    }
}

/// The main button of a screen, filled with the accent (`.borderedProminent` keeps white text,
/// unreadable on the dark-mode accent).
struct AccentButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize

    func makeBody(configuration: Configuration) -> some View {
        let large = controlSize == .large
        configuration.label
            .font(.system(size: large ? 13 : 12, weight: .medium))
            .foregroundStyle(Theme.onAccent)
            .padding(.horizontal, large ? 14 : 10)
            .padding(.vertical, large ? 6 : 3)
            .background(Theme.accent, in: RoundedRectangle(cornerRadius: large ? 7 : 5, style: .continuous))
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
            .contentShape(Rectangle())
    }
}
