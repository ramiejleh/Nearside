// Placeholders where this system's sockets, mDNS and USB aren't written yet (Windows: Winsock,
// DnsServiceBrowse, WinUSB). Same API as the Mac's; everything fails or finds nothing.
#if !canImport(Darwin)
import Foundation

final class TCPSocket: Channel, @unchecked Sendable {
    init(host: String, port: UInt16, timeout: TimeInterval) throws {
        throw AdbError.connect("not on this system yet")
    }
    var sslHandle: Int32 { -1 }
    func setReadTimeout(_ seconds: TimeInterval) {}
    func setNonBlocking() {}
    func wait(readable: Bool) throws { throw AdbError.closed }
    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int { throw AdbError.closed }
    func write(_ data: Data) throws { throw AdbError.closed }
    func close() {}
}

public enum Discovery {
    public struct Service: Sendable, Equatable {
        public let name: String
        public let host: String
        public let port: UInt16
    }
    public static let connectType = "_adb-tls-connect._tcp"
    public static let pairingType = "_adb-tls-pairing._tcp"
    public static func browse(_ type: String, timeout: TimeInterval = 1.5) -> [Service] { [] }
}

public enum USB {
    public struct Device: Sendable, Equatable {
        public let serial: String
        public let id: UInt64
    }
    public static func devices() -> [Device] { [] }
    static func open(_ device: Device) throws -> any Channel { throw AdbError.connect("not on this system yet") }
}
#endif
