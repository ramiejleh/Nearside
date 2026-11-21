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
