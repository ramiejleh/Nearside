import Foundation
import Testing
@testable import NearsideCore

/// Muted notifications: held while muted, shown when it ends (if still on the phone).
@Suite struct NotificationSnoozeTests {
    private func note(_ key: String, minutesAgo: Double) -> PhoneNotification {
        PhoneNotification(key: key, package: "app", app: "App", title: key, text: "",
                          posted: Date().addingTimeInterval(-minutesAgo * 60), actions: [])
    }

    @Test func onUntilItsTime() {
        let now = Date()
        var snooze = NotificationSnooze()
        #expect(!snooze.isOn(at: now))
        snooze.start(until: now.addingTimeInterval(3600))
        #expect(snooze.isOn(at: now))
        #expect(!snooze.isOn(at: now.addingTimeInterval(3601)))
        snooze.start(until: .distantFuture)
        #expect(snooze.isIndefinite && snooze.isOn(at: now.addingTimeInterval(1e9)))
    }

    @Test func showsOnlyWhatsStillOnThePhoneNewestFirst() {
        var snooze = NotificationSnooze(until: .distantFuture)
        for key in ["a", "b", "c", "gone"] { snooze.hold(key, quiet: false) }
        snooze.drop("gone")
        let current = [note("a", minutesAgo: 30), note("b", minutesAgo: 5), note("c", minutesAgo: 10), note("before", minutesAgo: 60)]
        let shown = snooze.end(current: current)
        #expect(shown.map(\.0.key) == ["b", "c", "a"])
        #expect(!snooze.isOn())
    }

    @Test func bannersForTheNewestFewOnly() {
        var snooze = NotificationSnooze(until: .distantFuture)
        let current = (0..<5).map { note("n\($0)", minutesAgo: Double($0)) }
        current.forEach { snooze.hold($0.key, quiet: false) }
        let shown = snooze.end(current: current)
        #expect(shown.map(\.quiet) == [false, false, false, true, true])
    }

    @Test func onesThePhoneSentBeforeStayQuiet() {
        var snooze = NotificationSnooze(until: .distantFuture)
        snooze.hold("old", quiet: true)  // a reconnect's catch-up resending it
        snooze.hold("new", quiet: false)
        snooze.hold("new", quiet: true)  // updated since: it still never alerted
        let shown = snooze.end(current: [note("old", minutesAgo: 1), note("new", minutesAgo: 2)])
        #expect(shown.map(\.quiet) == [true, false])
    }

    @Test func keepOnlyPrunesWhatThePhoneNoLongerHas() {
        var snooze = NotificationSnooze(until: .distantFuture)
        snooze.hold("a", quiet: false)
        snooze.hold("b", quiet: false)
        snooze.keepOnly(["b"])
        #expect(snooze.end(current: [note("a", minutesAgo: 1), note("b", minutesAgo: 1)]).map(\.0.key) == ["b"])
    }
}
