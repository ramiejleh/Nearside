import CoreGraphics

/// Turns Mac trackpad gestures into the fingers Android expects (pure, so it's tested).
///
/// - Two-finger scroll becomes one finger dragging from the pointer: the app scrolls, and on lift
///   flings, with its own physics (Mac momentum events are ignored; Android makes its own).
/// - Pinch and rotate become two fingers around the pointer.
///
/// Positions are in video points, y down (the view's aspect-fit video rect); touches come out
/// normalised to the video. Fingers start inside the video (a touch that lands outside every window
/// is rejected), but may move past its edges, which Android delivers to the window they started on.
public struct PointerGestures: Sendable {
    public struct Touch: Equatable, Sendable {
        public let action: DisplayWire.TouchAction
        public let pointer: UInt8
        public let x: Float
        public let y: Float
    }

    public enum Phase: Sendable { case began, changed, ended }

    /// Pointer ids: 0 is the mouse button (StreamView), these are the gestures'.
    static let scrollFinger: UInt8 = 1, pinchFingers: (UInt8, UInt8) = (2, 3)

    public var size: CGSize
    private var scroll: CGPoint?
    private var pinch: (center: CGPoint, span: CGFloat, angle: CGFloat)?
    private var magnifying = false, rotating = false

    public init(size: CGSize) { self.size = size }

    public var isActive: Bool { scroll != nil || pinch != nil }

    // MARK: Scroll

    /// `delta` is NSEvent.scrollingDelta in points (+y = content moves down, whatever the
    /// natural-scrolling setting, so the finger simply moves by it).
    public mutating func scroll(_ phase: Phase, at point: CGPoint, delta: CGVector) -> [Touch] {
        switch phase {
        case .began:
            var out = scroll.map { [touch(.up, Self.scrollFinger, $0)] } ?? []
            let start = inside(point, margin: 1)
            scroll = start
            out.append(touch(.down, Self.scrollFinger, start))
            if delta != .zero { out += self.scroll(.changed, at: point, delta: delta) }
            return out
        case .changed:
            // Began outside the window, or before it was key: start here.
            guard var p = scroll else { return self.scroll(.began, at: point, delta: delta) }
            p.x += delta.dx
            p.y += delta.dy
            // Far past the edge Android may not deliver it any more; stop there.
            p.x = min(max(p.x, -2 * size.width), 3 * size.width)
            p.y = min(max(p.y, -2 * size.height), 3 * size.height)
            scroll = p
            return [touch(.move, Self.scrollFinger, p)]
        case .ended:
            guard let p = scroll else { return [] }
            scroll = nil
            return [touch(.up, Self.scrollFinger, p)]
        }
    }

    // MARK: Pinch and rotate

    /// `magnification` is NSEvent.magnification (a change: the span is multiplied by 1 + it).
    public mutating func magnify(_ phase: Phase, at point: CGPoint, by magnification: CGFloat) -> [Touch] {
        twoFinger(phase, at: point, flag: \.magnifying) { $0.span *= max(0.1, 1 + magnification) }
    }

    /// `degrees` is NSEvent.rotation (a change, counterclockwise on screen).
    public mutating func rotate(_ phase: Phase, at point: CGPoint, by degrees: CGFloat) -> [Touch] {
        twoFinger(phase, at: point, flag: \.rotating) { $0.angle -= degrees * .pi / 180 } // y is down
    }

    private mutating func twoFinger(_ phase: Phase, at point: CGPoint, flag: WritableKeyPath<PointerGestures, Bool>,
                                    change: (inout (center: CGPoint, span: CGFloat, angle: CGFloat)) -> Void) -> [Touch] {
        switch phase {
        case .began:
            self[keyPath: flag] = true
            guard pinch == nil else { return [] } // the other gesture already put the fingers down
            let span = min(min(size.width, size.height) * 0.3, 200)
            pinch = (inside(point, margin: span / 2 + 1), span, 0)
            let (a, b) = fingers()
            return [touch(.down, Self.pinchFingers.0, a), touch(.down, Self.pinchFingers.1, b)]
        case .changed:
            guard var p = pinch else { return [] }
            change(&p)
            p.span = min(max(p.span, 8), 4 * max(size.width, size.height))
            pinch = p
            let (a, b) = fingers()
            return [touch(.move, Self.pinchFingers.0, a), touch(.move, Self.pinchFingers.1, b)]
        case .ended:
            self[keyPath: flag] = false
            guard pinch != nil, !magnifying, !rotating else { return [] }
            let (a, b) = fingers()
            pinch = nil
            return [touch(.up, Self.pinchFingers.1, b), touch(.up, Self.pinchFingers.0, a)]
        }
    }

    private func fingers() -> (CGPoint, CGPoint) {
        guard let p = pinch else { return (.zero, .zero) }
        let dx = cos(p.angle) * p.span / 2, dy = sin(p.angle) * p.span / 2
        return (CGPoint(x: p.center.x - dx, y: p.center.y - dy), CGPoint(x: p.center.x + dx, y: p.center.y + dy))
    }

    /// Lifts every gesture finger (the window lost focus mid-gesture, say).
    public mutating func cancel() -> [Touch] {
        var out: [Touch] = []
        if let p = scroll { out.append(touch(.up, Self.scrollFinger, p)) }
        if pinch != nil {
            let (a, b) = fingers()
            out += [touch(.up, Self.pinchFingers.1, b), touch(.up, Self.pinchFingers.0, a)]
        }
        scroll = nil; pinch = nil; magnifying = false; rotating = false
        return out
    }

    // MARK: Helpers

    private func inside(_ p: CGPoint, margin: CGFloat) -> CGPoint {
        let mx = min(margin, size.width / 2), my = min(margin, size.height / 2)
        return CGPoint(x: min(max(p.x, mx), size.width - mx), y: min(max(p.y, my), size.height - my))
    }

    private func touch(_ action: DisplayWire.TouchAction, _ pointer: UInt8, _ p: CGPoint) -> Touch {
        Touch(action: action, pointer: pointer, x: Float(p.x / max(size.width, 1)), y: Float(p.y / max(size.height, 1)))
    }
}
