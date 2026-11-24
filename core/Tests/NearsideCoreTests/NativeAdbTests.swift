import Foundation
import NativeAdb
import Testing

/// Live tests against a real phone: NEARSIDE_DEVICE=ip:port (its wireless-debugging port).
@Suite(.enabled(if: ProcessInfo.processInfo.environment["NEARSIDE_DEVICE"] != nil))
struct NativeAdbLiveTests {
    let host: String
    let port: UInt16

    init() {
        let parts = ProcessInfo.processInfo.environment["NEARSIDE_DEVICE"]!.split(separator: ":")
        host = String(parts[0])
        port = UInt16(parts[1])!
    }

    @Test func connectsAndRunsShellCommands() throws {
        let key = try AdbKey(pemFile: AdbKey.defaultPath)
        let started = Date()
        let adb = try AdbConnection.connect(host: host, port: port, key: key, expectedPeerKey: nil)
        defer { adb.close() }
        print("connected in \(Int(Date().timeIntervalSince(started) * 1000)) ms; model=\(adb.property("ro.product.model") ?? "?")")
        #expect(adb.peerKeySHA256.count == 32)

        let serial = try adb.shell("getprop ro.serialno")
        #expect(serial.ok)
        print("serial length \(serial.output.count)")
        #expect(try adb.shell("true").exitCode == 0)
        #expect(try adb.shell("exit 3").exitCode == 3)
        let big = try adb.shell("head -c 300000 /dev/zero | tr '\\\\0' 'x'")
        #expect(big.stdout.count == 300_000)
        #expect(try adb.shell("echo oops >&2; exit 1").stderr == Data("oops\n".utf8))
    }

    @Test func phoneKeyIsStableAcrossConnections() throws {
        let key = try AdbKey(pemFile: AdbKey.defaultPath)
        let a = try AdbConnection.connect(host: host, port: port, key: key, expectedPeerKey: nil)
        let first = a.peerKeySHA256
        a.close()
        // Pinned to the right key: connects. Pinned to any other key: refused before adb data.
        let b = try AdbConnection.connect(host: host, port: port, key: key, expectedPeerKey: first)
        b.close()
        var other = first
        other[other.startIndex] ^= 0xFF
        #expect(throws: AdbError.self) {
            try AdbConnection.connect(host: host, port: port, key: key, expectedPeerKey: other)
        }
    }

    @Test func discoversThePhoneOverMDNS() {
        let services = Discovery.browse(Discovery.connectType)
        print("mDNS: \(services.map { "\($0.host):\($0.port)" })")
        #expect(services.contains { $0.port == port })
    }

    @Test func pushPullAndBack() throws {
        let adb = try AdbConnection.connect(host: host, port: port, key: try AdbKey(pemFile: AdbKey.defaultPath), expectedPeerKey: nil)
        defer { adb.close() }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let original = dir.appendingPathComponent("in.bin")
        var bytes = [UInt8](repeating: 0, count: 5_000_123)
        for i in bytes.indices { bytes[i] = UInt8(truncatingIfNeeded: i &* 31 &+ 7) }
        try Data(bytes).write(to: original)
        let remote = "/data/local/tmp/nearside-native-test.bin"
        let t0 = Date()
        try adb.push(original, to: remote)
        let t1 = Date()
        let back = dir.appendingPathComponent("out.bin")
        try adb.pull(remote, to: back)
        let t2 = Date()
        print("push 5 MB: \(Int(t1.timeIntervalSince(t0) * 1000)) ms, pull: \(Int(t2.timeIntervalSince(t1) * 1000)) ms")
        #expect(try Data(contentsOf: back) == Data(bytes))
        let mtime = try adb.shell("stat -c %Y \(remote)").output
        #expect(abs((Double(mtime) ?? 0) - Date().timeIntervalSince1970) < 120) // "now", not the Mac's date
        _ = try adb.shell("rm \(remote)")
        #expect(throws: AdbError.self) { try adb.pull("/nonexistent/file", to: dir.appendingPathComponent("x")) }
    }

    @Test func manyStreamsAtOnce() throws {
        let adb = try AdbConnection.connect(host: host, port: port, key: try AdbKey(pemFile: AdbKey.defaultPath), expectedPeerKey: nil)
        defer { adb.close() }
        final class Results: @unchecked Sendable { let lock = NSLock(); var codes = [Int32](repeating: -1, count: 8) }
        let results = Results()
        DispatchQueue.concurrentPerform(iterations: 8) { i in
            let code = (try? adb.shell("exit \(i)").exitCode) ?? -1
            results.lock.withLock { results.codes[i] = code }
        }
        #expect(results.codes == Array(0..<8))
    }
}

extension NativeAdbLiveTests {
    /// Reinstalls the Nearside phone app (opt in separately: NEARSIDE_INSTALL_APK=path).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NEARSIDE_INSTALL_APK"] != nil))
    func installsAnApk() throws {
        let adb = try AdbConnection.connect(host: host, port: port, key: try AdbKey(pemFile: AdbKey.defaultPath), expectedPeerKey: nil)
        defer { adb.close() }
        let t0 = Date()
        let result = try adb.install(URL(fileURLWithPath: ProcessInfo.processInfo.environment["NEARSIDE_INSTALL_APK"]!))
        print("install: \(result) in \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
        #expect(result.hasPrefix("Success"))
    }
}

@Suite struct AdbKeyTests {
    @Test func androidPublicKeyMatchesStockAdb() throws {
        let pubPath = AdbKey.defaultPath + ".pub"
        guard let stock = try? String(contentsOfFile: pubPath, encoding: .utf8) else { return } // no adb on this Mac
        let key = try AdbKey(pemFile: AdbKey.defaultPath)
        let ours = try key.androidPublicKey(comment: "x@y")
        #expect(ours.split(separator: " ")[0] == stock.split(separator: " ")[0])
    }

    @Test func generatedKeysRoundTripThroughPEM() throws {
        let key = try AdbKey.generate()
        let pem = try key.pemData()
        #expect(String(decoding: pem, as: UTF8.self).hasPrefix("-----BEGIN PRIVATE KEY-----"))
        let again = try AdbKey(pem: pem)
        #expect(try again.androidPublicKey(comment: "a@b") == key.androidPublicKey(comment: "a@b"))
        #expect(Data(base64Encoded: String(try key.androidPublicKey(comment: "").split(separator: " ")[0]))?.count == 524)
    }
}
