import AppKit

/// Test hook: NEARSIDE_TEST_SHOT=<png> saves a phone-app or phone window as it looks: toolbar,
/// overlays (such as the notification panel) and the app's picture, inside the rounded corners.
/// A view capture leaves the Metal picture black, so the latest frame is drawn into the picture's
/// place and the views above it are drawn again on top. NEARSIDE_TEST_SHOT_AFTER: seconds after
/// the window shows (default 4).
@MainActor
enum WindowShot {
    static var path: String? { ProcessInfo.processInfo.environment["NEARSIDE_TEST_SHOT"] }
    static var delay: Double { Double(ProcessInfo.processInfo.environment["NEARSIDE_TEST_SHOT_AFTER"] ?? "") ?? 4 }

    static func saveSoon(window: NSWindow, stream: StreamView) {
        guard let path else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { save(window: window, stream: stream, to: path) }
    }

    static func save(window: NSWindow, stream: StreamView, to path: String) {
        guard let view = window.contentView, let whole = capture(view) else { return }
        guard let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: whole.pixelsWide, pixelsHigh: whole.pixelsHigh,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        out.size = view.bounds.size // points, so drawing is in the view's coordinates (set before the context)
        guard let context = NSGraphicsContext(bitmapImageRep: out) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let radius = view.layer?.cornerRadius ?? 0
        NSBezierPath(roundedRect: view.bounds, xRadius: radius, yRadius: radius).addClip()
        whole.draw(in: view.bounds)
        if let picture = stream.renderer.shownImage() {
            context.cgContext.interpolationQuality = .high
            context.cgContext.draw(picture, in: stream.convert(stream.bounds, to: view))
        }
        // What lies above the picture (toolbar, panels), in order.
        if let siblings = stream.superview?.subviews, let index = siblings.firstIndex(of: stream) {
            for above in siblings[(index + 1)...] where !above.isHidden && above.alphaValue > 0 {
                capture(above)?.draw(in: above.convert(above.bounds, to: view))
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        try? out.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        NSLog("Nearside: window shot saved to \(path)")
    }

    private static func capture(_ view: NSView) -> NSBitmapImageRep? {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }
}
