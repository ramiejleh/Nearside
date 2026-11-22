import Darwin
import Foundation
@testable import NativeAdb
import Testing

/// A connection whose local address the Mac no longer has is dropped after a network change.
@Suite struct NetworkChangeTests {
    private func ipv4(_ text: String, port: UInt16 = 0) -> sockaddr_storage {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        inet_pton(AF_INET, text, &address.sin_addr)
        var storage = sockaddr_storage()
        withUnsafeBytes(of: address) { raw in withUnsafeMutableBytes(of: &storage) { $0.copyMemory(from: raw) } }
        return storage
    }

    @Test func comparesAddressesNotPorts() {
        #expect(TCPSocket.sameAddress(ipv4("192.168.0.20", port: 5000), ipv4("192.168.0.20", port: 6000)))
        #expect(!TCPSocket.sameAddress(ipv4("192.168.0.20"), ipv4("10.71.246.20")))
    }

    @Test func aLiveLoopbackConnectionKeepsItsAddress() throws {
        // A listener on 127.0.0.1, then a real TCPSocket to it.
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        #expect(listener >= 0)
        defer { close(listener) }
        var address = ipv4("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        #expect(bound == 0)
        #expect(listen(listener, 1) == 0)
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &length) }
        }
        let port = withUnsafeBytes(of: address) { UInt16(bigEndian: $0.load(fromByteOffset: 2, as: UInt16.self)) }

        let connection = try TCPSocket(host: "127.0.0.1", port: port, timeout: 2)
        #expect(!connection.localAddressGone)
        connection.close()
    }
}
