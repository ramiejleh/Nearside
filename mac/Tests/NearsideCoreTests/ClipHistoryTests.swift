import Foundation
import Testing
@testable import NearsideCore

@Suite struct AdbParsingTests {
    @Test func extractsHardwareSerialFromPairOutput() {
        let out = "Successfully paired to 192.168.0.76:37197 [guid=adb-ABC123XYZ0001-AbCdEf]"
        #expect(Adb.serialFromPairOutput(out) == "ABC123XYZ0001")
        #expect(Adb.serialFromPairOutput("Failed: Wrong password or connection was dropped.") == nil)
    }
}

@Suite struct ClipHistoryTests {
    @Test func addsNewestFirst() {
        var history = ClipHistory()
        history.add("one", source: .mac)
        history.add("two", source: .android)
        #expect(history.items.map(\.text) == ["two", "one"])
    }

    @Test func copyingSameTextMovesItToTopInsteadOfDuplicating() {
        var history = ClipHistory()
        history.add("a", source: .mac)
        history.add("b", source: .mac)
        history.add("a", source: .android)
        #expect(history.items.map(\.text) == ["a", "b"])
        #expect(history.items.first?.source == .android)
    }

    @Test func respectsLimitIncludingWhenLowered() {
        var history = ClipHistory(limit: 3)
        for i in 1...5 { history.add("\(i)", source: .mac) }
        #expect(history.items.map(\.text) == ["5", "4", "3"])
        history.limit = 1
        #expect(history.items.map(\.text) == ["5"])
    }

    @Test func promoteMovesToTopAndKeepsID() {
        var history = ClipHistory()
        let first = history.add("first", source: .android)
        history.add("second", source: .mac)
        history.promote(id: first.id)
        #expect(history.items.first?.id == first.id)
        #expect(history.items.count == 2)
    }

    @Test func filtersByQueryAndSource() {
        var history = ClipHistory()
        history.add("Hello from Pixel", source: .android)
        history.add("hello from Mac", source: .mac)
        history.add("unrelated", source: .android)
        #expect(history.filtered(query: "HELLO", source: nil).count == 2)
        #expect(history.filtered(query: "hello", source: .android).map(\.text) == ["Hello from Pixel"])
        #expect(history.filtered(query: "  ", source: .android).count == 2)
    }

    @Test func removeAndClear() {
        var history = ClipHistory()
        let item = history.add("x", source: .mac)
        history.add("y", source: .mac)
        history.remove(id: item.id)
        #expect(history.items.map(\.text) == ["y"])
        history.clear()
        #expect(history.items.isEmpty)
    }

    @Test func savesOwnerOnlyAndLoadsBack() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("history.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var history = ClipHistory(limit: 10)
        history.add("persist me", source: .android)
        try history.save(to: url)

        let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(perms == 0o600)
        let loaded = ClipHistory.load(from: url, limit: 10)
        #expect(loaded.items == history.items)
    }

    @Test func loadingMissingOrCorruptFileGivesEmptyHistory() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        #expect(ClipHistory.load(from: url, limit: 5).items.isEmpty)
        try Data("not json".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(ClipHistory.load(from: url, limit: 5).items.isEmpty)
    }
}
