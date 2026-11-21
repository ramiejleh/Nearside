import Foundation

/// Smooth motion: a jitter buffer for video. Frames reach the Mac unevenly (Wi-Fi delivers in
/// bunches), but they were captured evenly, so each is shown at its capture time plus one delay:
/// as small as the recent spread of arrival times allows. The delay rises at once when frames
/// start arriving later and eases back down over a few seconds once they're steady, and never
/// exceeds `maxDelay` beyond the quickest arrival (a stall shows late rather than delaying everything).
///
/// Times are seconds on the Mac's clock (CACurrentMediaTime); `pts` is the phone's capture time.
/// The two clocks' offset is unknown and doesn't matter: only differences of `arrival - pts`
/// are used.
public final class FramePacer<Frame>: @unchecked Sendable {
    private struct Waiting { let frame: Frame; let due: Double }

    /// Arrival spread covered: this share of recent frames arrives before it's due.
    public static var coverage: Double { 0.95 }
    public static var maxDelay: Double { 0.1 }
    /// How much of recent history to judge the spread by.
    static var window: Double { 2 }

    private let lock = NSLock()
    private var waiting: [Waiting] = []
    private var transits: [(at: Double, transit: Double)] = []
    /// `arrival - pts` a frame is shown at (the playout offset); nil until the first frame.
    private var offset: Double?

    public init() {}

    /// A frame decoded at `now`.
    public func add(_ frame: Frame, ptsMicros: Int64, now: Double) {
        let pts = Double(ptsMicros) / 1_000_000
        lock.withLock {
            let transit = now - pts
            // The phone's clock jumped (a new session, a reboot): start over.
            if let last = transits.last, abs(transit - last.transit) > 5 { transits.removeAll(); offset = nil }
            transits.append((now, transit))
            transits.removeFirst(transits.prefix { $0.at < now - Self.window }.count)
            let target = targetOffset()
            // Up at once (frames are arriving later than they're shown), down slowly.
            if let current = offset, target < current {
                offset = current - (current - target) * 0.02
            } else {
                offset = target
            }
            waiting.append(Waiting(frame: frame, due: max(pts + (offset ?? transit), now)))
        }
    }

    private func targetOffset() -> Double {
        let sorted = transits.map(\.transit).sorted()
        let quickest = sorted[0]
        let covered = sorted[min(sorted.count - 1, Int(Double(sorted.count) * Self.coverage))]
        return min(covered, quickest + Self.maxDelay)
    }

    /// The frame for the screen refresh at `time` (`refresh`: its length), or nil to keep the
    /// one shown. Frames are due within half a refresh of `time`. Behind by more than one (a
    /// bunch arrived late): skips to the newest two, so it catches up without leaping.
    public func next(at time: Double, refresh: Double) -> Frame? {
        lock.withLock {
            let due = waiting.prefix { $0.due <= time + refresh / 2 }.count
            guard due > 0 else { return nil }
            if due > 2 { waiting.removeFirst(due - 2) }
            return waiting.removeFirst().frame
        }
    }

    /// Frames waiting to be shown.
    public var count: Int { lock.withLock { waiting.count } }

    /// The current playout delay beyond the quickest recent arrival, seconds (statistics).
    public var addedDelay: Double {
        lock.withLock {
            guard let offset, let quickest = transits.map(\.transit).min() else { return 0 }
            return max(0, offset - quickest)
        }
    }

    /// Drops what's waiting (the window left the screen); keeps what it learned.
    public func clear() { lock.withLock { waiting.removeAll() } }
}
