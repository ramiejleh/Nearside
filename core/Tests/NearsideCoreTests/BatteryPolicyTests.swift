import Foundation
import Testing
@testable import NearsideCore

/// How often the Mac looks for a phone it can't reach (each try wakes the phone).
@Suite struct RetryDelayTests {
    @Test func growsFromThreeSecondsToAMinute() {
        let delays = (1...8).map { SyncEngine.retryDelay(afterFailures: $0) }
        #expect(delays == [3, 6, 12, 24, 48, 60, 60, 60])
    }

    @Test func noFailuresMeansTheShortestGap() {
        #expect(SyncEngine.retryDelay(afterFailures: 0) == 3)
    }
}

/// Fast pings keep the phone's Wi-Fi awake: only for the window that's about to get input.
@Suite struct PingPolicyTests {
    @Test func fastOnlyForTheWindowInUse() {
        #expect(PingPolicy.interval(level: .focused, pointerInside: true, sinceInput: 60) == 0.04)
        #expect(PingPolicy.interval(level: .focused, pointerInside: false, sinceInput: 3) == 0.04)
    }

    @Test func slowWhenNothingIsHappening() {
        #expect(PingPolicy.interval(level: .focused, pointerInside: false, sinceInput: 30) == 1)
        #expect(PingPolicy.interval(level: .visible, pointerInside: true, sinceInput: 0) == 1)
        #expect(PingPolicy.interval(level: .hidden, pointerInside: false, sinceInput: 0) == 5)
    }
}

/// The render thread's mailbox: never more than the newest frame waiting.
@Suite struct LatestBoxTests {
    @Test func aNewerValueReplacesOneStillWaiting() {
        let box = LatestBox<Int>()
        box.put(1); box.put(2); box.put(3)
        #expect(box.take() == 3)
        box.put(4)
        #expect(box.take() == 4)
    }

    @Test func closingEndsTheConsumer() async {
        let box = LatestBox<Int>()
        let consumer = Task.detached { box.take() }
        try? await Task.sleep(for: .milliseconds(50))
        box.close()
        #expect(await consumer.value == nil)
    }
}

/// Frames are split into NAL units without copying them; it must find what the copying split did.
@Suite struct NalRangeTests {
    @Test func rangesMatchTheUnits() {
        let stream = Data([0, 0, 0, 1, 0x40, 1, 2, 0, 0, 1, 0x26, 9, 9, 0, 0, 0, 1, 0x02, 7])
        let units = AnnexB.nalUnits(stream)
        let ranges = stream.withUnsafeBytes { AnnexB.nalRanges($0.bindMemory(to: UInt8.self)) }
        #expect(ranges.map { stream.subdata(in: $0) } == units)
        #expect(units.count == 3)
    }
}
