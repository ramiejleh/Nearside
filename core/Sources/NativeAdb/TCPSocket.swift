#if canImport(Darwin)
import Darwin
import Foundation

/// A connected TCP socket (blocking).
final class TCPSocket: Channel, @unchecked Sendable {
    let fd: Int32

    init(host: String, port: UInt16, timeout: TimeInterval) throws {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: IPPROTO_TCP,
                             ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &result) == 0, let info = result else {
            throw AdbError.connect("unknown host \(host)")
        }
        defer { freeaddrinfo(result) }
        let fd = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
        guard fd >= 0 else { throw AdbError.connect("socket: \(errno)") }
        var one: Int32 = 1
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &one, socklen_t(MemoryLayout<Int32>.size))
        // Wi-Fi priority (WMM) for interactive video: phone-app input and acks go out first.
        var service = NET_SERVICE_TYPE_VI
        setsockopt(fd, SOL_SOCKET, SO_NET_SERVICE_TYPE, &service, socklen_t(MemoryLayout<Int32>.size))
        // Data sent to a phone that vanished (Wi-Fi off, out of range) fails within ~20 s, so a
        // clip or notification never disappears into a dead link for long.
        var dropAfter: Int32 = 20
        setsockopt(fd, IPPROTO_TCP, TCP_RXT_CONNDROPTIME, &dropAfter, socklen_t(MemoryLayout<Int32>.size))
        Self.keepalive(fd, busy: false)

        // Connect with a timeout: non-blocking connect + poll, then back to blocking.
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        if Darwin.connect(fd, info.pointee.ai_addr, info.pointee.ai_addrlen) != 0 && errno != EINPROGRESS {
            Darwin.close(fd)
            throw AdbError.connect("connect: \(String(cString: strerror(errno)))")
        }
        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let ready = poll(&pfd, 1, Int32(timeout * 1000))
        var error: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length)
        guard ready == 1, error == 0 else {
            Darwin.close(fd)
            throw AdbError.connect(ready == 0 ? "timed out" : String(cString: strerror(error)))
        }
        _ = fcntl(fd, F_SETFL, flags)
        self.fd = fd
    }

    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        let n = Darwin.read(fd, buffer.baseAddress, buffer.count)
        guard n > 0 else { throw AdbError.closed }
        return n
    }

    func write(_ data: Data) throws {
        try data.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                let n = Darwin.write(fd, raw.baseAddress! + sent, raw.count - sent)
                guard n > 0 else { throw AdbError.closed }
                sent += n
            }
        }
    }

    func close() { shutdown(fd, SHUT_RDWR) }
    deinit { Darwin.close(fd) }

    /// Keepalive probes wake the phone's Wi-Fi and CPU, so they're rare unless phone-app windows
    /// are open: then a vanished phone is noticed within ~25 s (10 s quiet, 3 probes 5 s apart).
    /// Otherwise every 15 min: anything sent still notices a dead link quickly (above).
    func setKeepalive(busy: Bool) { Self.keepalive(fd, busy: busy) }

    /// The Mac no longer has the address this connection was made from (it moved to another
    /// network): the connection is dead, though TCP may take minutes to notice.
    var localAddressGone: Bool {
        var local = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let named = withUnsafeMutablePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard named == 0 else { return true }
        return !Self.interfaceAddresses().contains { Self.sameAddress($0, local) }
    }

    private static func interfaceAddresses() -> [sockaddr_storage] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        return sequence(first: first, next: { $0.pointee.ifa_next }).compactMap { entry in
            guard let address = entry.pointee.ifa_addr else { return nil }
            var copy = sockaddr_storage()
            withUnsafeMutableBytes(of: &copy) { out in
                out.copyMemory(from: UnsafeRawBufferPointer(start: address, count: Int(address.pointee.sa_len)))
            }
            return copy
        }
    }

    /// Same IP address (ports and scope aside).
    static func sameAddress(_ a: sockaddr_storage, _ b: sockaddr_storage) -> Bool {
        guard a.ss_family == b.ss_family else { return false }
        var a = a, b = b
        switch Int32(a.ss_family) {
        case AF_INET:
            return withUnsafeBytes(of: &a) { pa in withUnsafeBytes(of: &b) { pb in
                pa.load(fromByteOffset: 4, as: UInt32.self) == pb.load(fromByteOffset: 4, as: UInt32.self) // sin_addr
            } }
        case AF_INET6:
            return withUnsafeBytes(of: &a) { pa in withUnsafeBytes(of: &b) { pb in
                pa[8..<24].elementsEqual(pb[8..<24]) // sin6_addr
            } }
        default:
            return false
        }
    }

    /// Blocking reads give up after `seconds` (0: never).
    func setReadTimeout(_ seconds: TimeInterval) {
        var tv = timeval(tv_sec: Int(seconds), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    /// The socket for BoringSSL (SSL_set_fd).
    var sslHandle: Int32 { fd }

    /// After the TLS handshake: readers wait in `wait(readable:)` instead of blocking in SSL_read.
    func setNonBlocking() {
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
    }

    /// Until the socket can be read (or written); throws once it's closed.
    func wait(readable: Bool) throws {
        var pfd = pollfd(fd: fd, events: Int16(readable ? POLLIN : POLLOUT), revents: 0)
        let r = poll(&pfd, 1, -1)
        if r < 0 && errno != EINTR { throw AdbError.closed }
        if pfd.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 && pfd.revents & Int16(POLLIN) == 0 { throw AdbError.closed }
    }

    private static func keepalive(_ fd: Int32, busy: Bool) {
        var idle: Int32 = busy ? 10 : 900, interval: Int32 = busy ? 5 : 30, count: Int32 = 3
        let size = socklen_t(MemoryLayout<Int32>.size)
        setsockopt(fd, IPPROTO_TCP, TCP_KEEPALIVE, &idle, size)
        setsockopt(fd, IPPROTO_TCP, TCP_KEEPINTVL, &interval, size)
        setsockopt(fd, IPPROTO_TCP, TCP_KEEPCNT, &count, size)
    }
}
#endif
