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
        let adb = try AdbConnection.connect(host: host, port: port, key: key)
        defer { adb.close() }
        print("connected in \(Int(Date().timeIntervalSince(started) * 1000)) ms; model=\(adb.property("ro.product.model") ?? "?")")
        #expect(adb.peerKeySHA256?.count == 32)

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
        let a = try AdbConnection.connect(host: host, port: port, key: key)
        let first = a.peerKeySHA256
        a.close()
        let b = try AdbConnection.connect(host: host, port: port, key: key)
        defer { b.close() }
        #expect(first != nil && first == b.peerKeySHA256)
    }

    @Test func manyStreamsAtOnce() throws {
        let adb = try AdbConnection.connect(host: host, port: port, key: try AdbKey(pemFile: AdbKey.defaultPath))
        defer { adb.close() }
        let results = UnsafeMutableBufferPointer<Int32>.allocate(capacity: 8)
        defer { results.deallocate() }
        DispatchQueue.concurrentPerform(iterations: 8) { i in
            results[i] = (try? adb.shell("exit \(i)").exitCode) ?? -1
        }
        #expect(Array(results) == Array(0..<8))
    }
}
