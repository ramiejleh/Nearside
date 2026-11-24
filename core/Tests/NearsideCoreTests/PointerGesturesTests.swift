#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
import Testing
@testable import NearsideCore

struct PointerGesturesTests {
    let size = CGSize(width: 400, height: 800)

    @Test func scrollIsOneFingerDragFromThePointer() {
        var g = PointerGestures(size: size)
        // Fingers on the trackpad, not moving yet: nothing touches the app.
        #expect(g.scroll(.began, at: CGPoint(x: 200, y: 400), delta: .zero).isEmpty)
        #expect(!g.isActive)
        // Content moving up (fingers up, natural scrolling): the finger goes down, then moves up.
        let move = g.scroll(.changed, at: CGPoint(x: 200, y: 400), delta: CGVector(dx: 0, dy: -80))
        #expect(move == [.init(action: .down, pointer: 1, x: 0.5, y: 0.5), .init(action: .move, pointer: 1, x: 0.5, y: 0.4)])
        #expect(g.isActive)
        let up = g.scroll(.ended, at: .zero, delta: .zero)
        #expect(up == [.init(action: .up, pointer: 1, x: 0.5, y: 0.4)])
        #expect(!g.isActive)
    }

    @Test func scrollStartsInsideButMayLeave() {
        var g = PointerGestures(size: size)
        _ = g.scroll(.began, at: CGPoint(x: -50, y: 900), delta: .zero)
        let move = g.scroll(.changed, at: .zero, delta: CGVector(dx: 0, dy: 600))
        #expect(move[0].action == .down && move[0].x >= 0 && move[0].y <= 1)
        #expect(move[1].y > 1)
        // A huge scroll stops at the limit instead of running away.
        let far = g.scroll(.changed, at: .zero, delta: CGVector(dx: 0, dy: 1_000_000))
        #expect(far[0].y == 3)
    }

    @Test func aSlowStartStillClearsTheTouchSlop() {
        var g = PointerGestures(size: size)
        _ = g.scroll(.began, at: CGPoint(x: 200, y: 400), delta: .zero)
        let first = g.scroll(.changed, at: .zero, delta: CGVector(dx: 0, dy: -1)) // one point
        #expect(first.map(\.action) == [.down, .move])
        #expect(abs(CGFloat(first[0].y - first[1].y) * 800 - PointerGestures.firstMove) < 0.01) // moved the minimum
        let next = g.scroll(.changed, at: .zero, delta: CGVector(dx: 0, dy: -1))
        #expect(abs((first[1].y - next[0].y) * 800 - 1) < 0.01) // then exactly as the fingers move
    }

    @Test func restingFingersTouchNothing() {
        var g = PointerGestures(size: size)
        #expect(g.scroll(.began, at: CGPoint(x: 200, y: 400), delta: .zero).isEmpty)
        #expect(g.scroll(.ended, at: .zero, delta: .zero).isEmpty)
    }

    @Test func changedWithoutBeganStartsTheDrag() {
        var g = PointerGestures(size: size)
        let out = g.scroll(.changed, at: CGPoint(x: 100, y: 100), delta: CGVector(dx: 0, dy: 10))
        #expect(out.map(\.action) == [.down, .move])
    }

    @Test func pinchSpreadsTwoFingersAroundThePointer() {
        var g = PointerGestures(size: size)
        let down = g.magnify(.began, at: CGPoint(x: 200, y: 400), by: 0)
        #expect(down.map(\.action) == [.down, .down])
        #expect(down.map(\.pointer) == [2, 3])
        let span0 = (down[1].x - down[0].x) * 400
        let move = g.magnify(.changed, at: .zero, by: 1) // twice as far apart
        let span1 = (move[1].x - move[0].x) * 400
        #expect(abs(span1 - 2 * span0) < 0.01)
        #expect(abs((move[0].x + move[1].x) / 2 - 0.5) < 0.0001) // centred on the pointer
        let up = g.magnify(.ended, at: .zero, by: 0)
        #expect(up.map(\.action) == [.up, .up])
        #expect(!g.isActive)
    }

    @Test func pinchNearTheEdgeStartsWithBothFingersInside() {
        var g = PointerGestures(size: size)
        let down = g.magnify(.began, at: CGPoint(x: 0, y: 0), by: 0)
        #expect(down.allSatisfy { $0.x > 0 && $0.x < 1 && $0.y > 0 && $0.y < 1 })
    }

    @Test func rotateAndPinchShareTheFingersUntilBothEnd() {
        var g = PointerGestures(size: size)
        _ = g.magnify(.began, at: CGPoint(x: 200, y: 400), by: 0)
        #expect(g.rotate(.began, at: .zero, by: 0).isEmpty) // already down
        let turned = g.rotate(.changed, at: .zero, by: 90)
        #expect(abs(turned[0].x - turned[1].x) < 0.001) // now one above the other
        #expect(g.magnify(.ended, at: .zero, by: 0).isEmpty) // rotation still going
        #expect(g.rotate(.ended, at: .zero, by: 0).map(\.action) == [.up, .up])
    }

    @Test func cancelLiftsEverything() {
        var g = PointerGestures(size: size)
        _ = g.scroll(.began, at: CGPoint(x: 10, y: 10), delta: CGVector(dx: 0, dy: 5))
        _ = g.magnify(.began, at: CGPoint(x: 200, y: 400), by: 0)
        let out = g.cancel()
        #expect(out.map(\.action) == [.up, .up, .up])
        #expect(!g.isActive)
        #expect(g.cancel().isEmpty)
    }
}
