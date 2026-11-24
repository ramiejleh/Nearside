import Foundation
import Testing
@testable import NearsideCore

/// Smooth motion's jitter buffer: frames captured every 1/60 s, arriving unevenly.
@Suite struct FramePacerTests {
    let frame = 1.0 / 60

    /// Plays `arrivals` (seconds after capture, per frame) through a 60 Hz display; returns which
    /// frame each refresh showed (nil: none new).
    func play(_ delays: [Double], refreshes: Int) -> (shown: [Int?], pacer: FramePacer<Int>) {
        let pacer = FramePacer<Int>()
        let clockOffset = 1000.0 // the Mac's and phone's clocks differ; must not matter
        var events = delays.enumerated().map { (i, d) in (at: clockOffset + Double(i) * frame + d, index: i) }
        events.sort { $0.at < $1.at }
        var shown: [Int?] = []
        for r in 0..<refreshes {
            let tick = clockOffset + Double(r) * frame
            while let e = events.first, e.at <= tick {
                pacer.add(e.index, ptsMicros: Int64(Double(e.index) * frame * 1_000_000), now: e.at)
                events.removeFirst()
            }
            shown.append(pacer.next(at: tick + frame, refresh: frame))
        }
        return (shown, pacer)
    }

    @Test func steadyArrivalsAddNoDelay() {
        let (shown, pacer) = play(Array(repeating: 0.03, count: 120), refreshes: 120)
        #expect(pacer.addedDelay < 0.001)
        // After the first, every refresh shows the next frame.
        let tail = shown.compactMap { $0 }
        #expect(tail == Array(tail.first!...tail.last!))
        #expect(shown.dropFirst(5).allSatisfy { $0 != nil })
    }

    @Test func bunchedArrivalsAreSpreadBackOut() {
        // Wi-Fi delivering pairs: every other frame waits for the next one (an extra 1/60 s).
        let delays = (0..<240).map { $0 % 2 == 0 ? 0.03 + frame : 0.03 }
        let (shown, pacer) = play(delays, refreshes: 240)
        // Once it has learned the spread, one new frame every refresh, in order, none skipped.
        let settled = Array(shown.suffix(120))
        #expect(settled.allSatisfy { $0 != nil })
        let frames = settled.compactMap { $0 }
        #expect(zip(frames, frames.dropFirst()).allSatisfy { $1 == $0 + 1 })
        #expect(pacer.addedDelay > 0.01 && pacer.addedDelay < 0.03)
    }

    @Test func aStallIsCappedNotAddedToEverything() {
        // One frame 400 ms late: the delay never grows past maxDelay.
        var delays = Array(repeating: 0.02, count: 120)
        delays[60] = 0.4
        let (_, pacer) = play(delays, refreshes: 200)
        #expect(pacer.addedDelay <= FramePacer<Int>.maxDelay + 0.0001)
    }

    @Test func theDelayComesBackDownWhenArrivalsSteady() {
        var delays = (0..<120).map { $0 % 2 == 0 ? 0.03 + 2 * frame : 0.03 }
        delays += Array(repeating: 0.03, count: 480) // then a USB cable: steady
        let (_, pacer) = play(delays, refreshes: 600)
        #expect(pacer.addedDelay < 0.005)
    }

    @Test func fallingBehindSkipsToTheNewestTwo() {
        let pacer = FramePacer<Int>()
        for i in 0..<5 { pacer.add(i, ptsMicros: Int64(i) * 16_667, now: 1) } // all at once, late
        #expect(pacer.next(at: 2, refresh: frame) == 3)
        #expect(pacer.next(at: 2, refresh: frame) == 4)
        #expect(pacer.next(at: 2, refresh: frame) == nil)
    }
}
