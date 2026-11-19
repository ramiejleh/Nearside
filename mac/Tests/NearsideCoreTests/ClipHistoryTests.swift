import Foundation
import Testing
@testable import NearsideCore

@Suite struct AdbParsingTests {
    @Test func extractsHardwareSerialFromPairOutput() {
        let out = "Successfully paired to 192.168.0.76:37197 [guid=adb-ABC123XYZ0001-AbCdEf]"
        #expect(Adb.serialFromPairOutput(out) == "ABC123XYZ0001")
        #expect(Adb.serialFromPairOutput("Failed: Wrong password or connection was dropped.") == nil)
    }

    @Test func pinnedKeyHexRoundTrips() {
        let key = Data((0..<32).map { UInt8($0 * 7 & 0xFF) })
        #expect(Data(hexString: key.hexString) == key)
        #expect(Data(hexString: "abc") == nil)   // odd length
        #expect(Data(hexString: "zz") == nil)    // not hex
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

@Suite struct QuarantineTests {
    @Test func receivedFilesGetTheQuarantineFlag() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("q-\(UUID().uuidString).command")
        try Data("echo hi".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        SyncEngine.quarantine(url)
        var buffer = [CChar](repeating: 0, count: 256)
        let length = getxattr(url.path, "com.apple.quarantine", &buffer, buffer.count, 0, 0)
        #expect(length > 0)
        #expect(String(cString: buffer).hasPrefix("0083;"))
    }
}

@Suite struct MessagesStoreTests {
    @Test func sameNumberIgnoresFormattingAndCountryCode() {
        #expect(MessagesStore.sameNumber("+45 12 34 56 78", "12345678"))
        #expect(MessagesStore.sameNumber("(555) 010-9999", "5550109999"))
        #expect(!MessagesStore.sameNumber("12345678", "87654321"))
        #expect(MessagesStore.sameNumber("Netflix", "Netflix"))
    }

    @Test func parsesThreadsAndMessages() {
        let thread = MessagesStore.thread(["thread": NSNumber(value: 7), "address": "+4512345678", "name": "",
                                           "snippet": "hi", "date": NSNumber(value: 1_700_000_000_000), "out": true, "unread": NSNumber(value: 2)])
        #expect(thread?.id == 7)
        #expect(thread?.title == "+4512345678") // empty name falls back to the number
        #expect(thread?.unread == 2)
        #expect(thread?.date == Date(timeIntervalSince1970: 1_700_000_000))
        let message = MessagesStore.message(["id": NSNumber(value: 3), "body": "yo", "date": NSNumber(value: 0), "out": false])
        #expect(message?.outgoing == false && message?.failed == false)
        #expect(MessagesStore.message(["body": "no id"]) == nil)
    }
}

@Suite struct AdbInstallerTests {
    @Test func acceptsOnlyGoogleSignedAdb() throws {
        let sdkAdb = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Android/sdk/platform-tools/adb")
        if FileManager.default.fileExists(atPath: sdkAdb.path) {
            #expect(AdbInstaller.isGoogleSigned(sdkAdb))
            // A modified copy must fail, even though it started out as Google's.
            let copy = FileManager.default.temporaryDirectory.appendingPathComponent("adb-\(UUID().uuidString)")
            try FileManager.default.copyItem(at: sdkAdb, to: copy)
            defer { try? FileManager.default.removeItem(at: copy) }
            let handle = try FileHandle(forWritingTo: copy)
            try handle.seek(toOffset: 4096)
            try handle.write(contentsOf: Data([0xFF, 0x00, 0xFF]))
            try handle.close()
            #expect(!AdbInstaller.isGoogleSigned(copy))
        }
        #expect(!AdbInstaller.isGoogleSigned(URL(fileURLWithPath: "/bin/ls"))) // Apple-signed, not Google
        #expect(!AdbInstaller.isGoogleSigned(URL(fileURLWithPath: "/nonexistent/adb")))
    }

    /// Real download from Google; opt in with NEARSIDE_NET_TESTS=1.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NEARSIDE_NET_TESTS"] == "1"))
    func downloadsAndInstallsGooglesAdb() async throws {
        let started = Date()
        let result = await AdbInstaller.install { _ in }
        let adb = try result.get()
        print("installed in \(Int(Date().timeIntervalSince(started))) s at \(adb.path)")
        #expect(FileManager.default.isExecutableFile(atPath: adb.path))
        #expect(AdbInstaller.isGoogleSigned(adb))
    }
}

@Suite struct BubbleLayoutTests {
    private func msg(_ id: Int64, _ out: Bool, _ seconds: TimeInterval) -> MessagesStore.Message {
        .init(id: id, body: "", date: Date(timeIntervalSince1970: 1_700_000_000 + seconds), outgoing: out, failed: false, pending: false)
    }

    @Test func groupsCloseMessagesFromTheSameSide() {
        let messages = [msg(1, false, 0), msg(2, false, 30), msg(3, false, 60), // a run of three
                        msg(4, true, 70),                                      // reply: new run
                        msg(5, true, 70 + 600)]                                // 10 min later: new run
        let l = MessagesStore.layout(messages)
        #expect(l.map(\.first) == [true, false, false, true, true])
        #expect(l.map(\.last) == [false, false, true, true, true])
        #expect(l.map(\.header) == [true, false, false, false, false])
    }

    @Test func longPauseGetsAHeaderAndBreaksTheRun() {
        let l = MessagesStore.layout([msg(1, true, 0), msg(2, true, 2 * 3600)])
        #expect(l.map(\.header) == [true, true])
        #expect(l[0].last && l[1].first)
    }
}
