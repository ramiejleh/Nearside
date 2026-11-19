import Foundation
import Testing
@testable import NearsideCore

@Suite struct AdbParsingTests {
    @Test func extractsHardwareSerialFromPairOutput() {
        let out = "Successfully paired to 192.168.0.76:37197 [guid=adb-ABC123XYZ0001-AbCdEf]"
        #expect(Adb.serialFromPairOutput(out) == "ABC123XYZ0001")
        #expect(Adb.serialFromPairOutput("Failed: Wrong password or connection was dropped.") == nil)
    }

    @Test func parsesMdnsServicesByType() {
        let out = """
        List of discovered mdns services
        adb-ABC123XYZ0001-AbCdEf\t_adb-tls-connect._tcp\t192.168.0.76:42935
        nearside-abcd2345\t_adb-tls-pairing._tcp\t192.168.0.76:40111
        adb-ABC123XYZ0001-AbCdEf\t_adb._tcp\t192.168.0.76:5555
        """
        let pairing = Adb.services(out, type: "_adb-tls-pairing._tcp")
        #expect(pairing.map(\.instance) == ["nearside-abcd2345"])
        #expect(pairing.map(\.address) == ["192.168.0.76:40111"])
        #expect(Adb.services(out, type: "_adb-tls-connect._tcp").map(\.address) == ["192.168.0.76:42935"])
    }
}

@Suite struct QRPairingTests {
    @Test func payloadMatchesAndroidFormat() {
        #expect(QRPairing(name: "nearside-x", password: "pw").payload == "WIFI:T:ADB;S:nearside-x;P:pw;;")
    }

    @Test func randomSessionsAreUniqueAndSafe() {
        let a = QRPairing.random(), b = QRPairing.random()
        #expect(a != b)
        #expect(a.name.hasPrefix("nearside-"))
        #expect(a.password.count == 12)
        #expect((a.name + a.password).allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" })
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

@Suite struct FileNamesTests {
    @Test func stripsDirectoriesHiddenDotsAndControlCharacters() {
        #expect(FileNames.safe("../../etc/passwd") == "passwd")
        #expect(FileNames.safe(".hidden") == "hidden")
        #expect(FileNames.safe("a\u{0}b\nc.txt") == "abc.txt")
        #expect(FileNames.safe("") == "file")
        #expect(FileNames.safe("...") == "file")
        #expect(FileNames.safe("weird:name.pdf") == "weirdname.pdf")
    }

    @Test func numbersBeforeTheExtension() {
        #expect(FileNames.numbered("photo.jpg", 2) == "photo (2).jpg")
        #expect(FileNames.numbered("README", 3) == "README (3)")
    }

    @Test func uniqueAvoidsExistingFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(FileNames.unique("a.txt", in: dir).lastPathComponent == "a.txt")
        try Data().write(to: dir.appendingPathComponent("a.txt"))
        try Data().write(to: dir.appendingPathComponent("a (2).txt"))
        #expect(FileNames.unique("a.txt", in: dir).lastPathComponent == "a (3).txt")
    }

    @Test func shellQuoteSurvivesQuotes() {
        #expect(Adb.shellQuote("it's.txt") == "'it'\\''s.txt'")
    }
}
