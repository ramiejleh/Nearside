#if os(Windows)
import Foundation
import WinSDK

/// A connected TCP socket (blocking), with Winsock. Same behaviour as the Mac's (TCPSocket.swift).
final class TCPSocket: Channel, @unchecked Sendable {
    let fd: SOCKET

    /// Winsock needs starting once per process.
    private static let started: Bool = {
        var data = WSADATA()
        return WSAStartup(0x0202, &data) == 0
    }()

    init(host: String, port: UInt16, timeout: TimeInterval) throws {
        guard Self.started else { throw AdbError.connect("Winsock didn't start") }
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = Int32(IPPROTO_TCP.rawValue)
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &result) == 0, let info = result else {
            throw AdbError.connect("unknown host \(host)")
        }
        defer { freeaddrinfo(result) }
        let fd = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
        guard fd != INVALID_SOCKET else { throw AdbError.connect("socket: \(WSAGetLastError())") }
        Self.setOption(fd, Int32(IPPROTO_TCP.rawValue), TCP_NODELAY, 1)
        Self.setOption(fd, SOL_SOCKET, SO_KEEPALIVE, 1)
        // Data sent to a phone that vanished fails within ~20 s (the Mac's TCP_RXT_CONNDROPTIME).
        Self.setOption(fd, Int32(IPPROTO_TCP.rawValue), Self.tcpMaxRetransmitSeconds, 20)
        Self.keepalive(fd, busy: false)

        // Connect with a timeout: non-blocking connect + poll, then back to blocking.
        Self.setBlocking(fd, false)
        if connect(fd, info.pointee.ai_addr, Int32(info.pointee.ai_addrlen)) != 0 && WSAGetLastError() != WSAEWOULDBLOCK {
            let error = WSAGetLastError()
            closesocket(fd)
            throw AdbError.connect("connect: \(error)")
        }
        var pfd = WSAPOLLFD(fd: fd, events: Int16(POLLOUT), revents: 0)
        let ready = WSAPoll(&pfd, 1, Int32(timeout * 1000))
        var error: Int32 = 0
        var length = Int32(MemoryLayout<Int32>.size)
        _ = withUnsafeMutableBytes(of: &error) { getsockopt(fd, SOL_SOCKET, SO_ERROR, $0.baseAddress!.assumingMemoryBound(to: CChar.self), &length) }
        guard ready == 1, error == 0, pfd.revents & Int16(POLLERR | POLLHUP) == 0 else {
            closesocket(fd)
            throw AdbError.connect(ready == 0 ? "timed out" : "connect: \(error)")
        }
        Self.setBlocking(fd, true)
        self.fd = fd
    }

    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        let n = recv(fd, buffer.baseAddress!.assumingMemoryBound(to: CChar.self), Int32(min(buffer.count, Int(Int32.max))), 0)
        guard n > 0 else { throw AdbError.closed }
        return Int(n)
    }

    func write(_ data: Data) throws {
        try data.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                let n = send(fd, (raw.baseAddress! + sent).assumingMemoryBound(to: CChar.self), Int32(min(raw.count - sent, Int(Int32.max))), 0)
                guard n > 0 else { throw AdbError.closed }
                sent += Int(n)
            }
        }
    }

    func close() { shutdown(fd, SD_BOTH) }
    deinit { closesocket(fd) }

    /// As on the Mac: rare keepalive probes unless phone-app windows are open.
    func setKeepalive(busy: Bool) { Self.keepalive(fd, busy: busy) }

    /// This PC no longer has the address the connection was made from (it moved to another
    /// network): binding a new socket to that address fails then.
    var localAddressGone: Bool {
        var local = sockaddr_storage()
        var length = Int32(MemoryLayout<sockaddr_storage>.size)
        let named = withUnsafeMutablePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard named == 0 else { return true }
        let probe = socket(Int32(local.ss_family), SOCK_DGRAM, 0)
        guard probe != INVALID_SOCKET else { return false }
        defer { closesocket(probe) }
        // Port 0: any free port, the address is what's checked.
        withUnsafeMutableBytes(of: &local) { $0[2] = 0; $0[3] = 0 }
        let bound = withUnsafePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(probe, $0, length) }
        }
        return bound != 0 && WSAGetLastError() == WSAEADDRNOTAVAIL
    }

    func setReadTimeout(_ seconds: TimeInterval) {
        Self.setOption(fd, SOL_SOCKET, SO_RCVTIMEO, Int32(seconds * 1000)) // milliseconds here
    }

    /// The socket for BoringSSL (SSL_set_fd, which takes a SOCKET as an int on Windows).
    var sslHandle: Int32 { Int32(truncatingIfNeeded: fd) }

    func setNonBlocking() { Self.setBlocking(fd, false) }

    /// Until the socket can be read (or written); throws once it's closed.
    func wait(readable: Bool) throws {
        var pfd = WSAPOLLFD(fd: fd, events: Int16(readable ? POLLRDNORM : POLLWRNORM), revents: 0)
        let r = WSAPoll(&pfd, 1, -1)
        if r < 0 { throw AdbError.closed }
        if pfd.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 && pfd.revents & Int16(POLLRDNORM) == 0 { throw AdbError.closed }
    }

    // ws2ipdef.h: TCP_MAXRT (seconds), TCP_KEEPIDLE, TCP_KEEPCNT, TCP_KEEPINTVL.
    private static let tcpMaxRetransmitSeconds: Int32 = 5
    private static let tcpKeepIdle: Int32 = 3, tcpKeepCount: Int32 = 16, tcpKeepInterval: Int32 = 17

    private static func keepalive(_ fd: SOCKET, busy: Bool) {
        setOption(fd, Int32(IPPROTO_TCP.rawValue), tcpKeepIdle, busy ? 10 : 900)
        setOption(fd, Int32(IPPROTO_TCP.rawValue), tcpKeepInterval, busy ? 5 : 30)
        setOption(fd, Int32(IPPROTO_TCP.rawValue), tcpKeepCount, 3)
    }

    private static func setOption(_ fd: SOCKET, _ level: Int32, _ name: Int32, _ value: Int32) {
        var value = value
        _ = withUnsafeBytes(of: &value) {
            setsockopt(fd, level, name, $0.baseAddress!.assumingMemoryBound(to: CChar.self), Int32(MemoryLayout<Int32>.size))
        }
    }

    private static func setBlocking(_ fd: SOCKET, _ blocking: Bool) {
        var mode: u_long = blocking ? 0 : 1
        _ = ioctlsocket(fd, Int32(bitPattern: 0x8004_667E), &mode) // FIONBIO
    }
}
#endif
