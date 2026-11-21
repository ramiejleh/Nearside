import CNIOBoringSSL
import Darwin
import Foundation

public enum AdbError: Error, CustomStringConvertible, Sendable {
    case connect(String)
    case closed
    case timeout
    case protocolError(String)
    case tls(String)
    case refused(String) // OPEN rejected: unknown service, etc.
    case wrongPhone      // its TLS key isn't the one we pinned
    case needsApproval   // USB: the phone hasn't allowed this Mac's key yet

    public var description: String {
        switch self {
        case .connect(let m): "can't connect: \(m)"
        case .closed: "connection closed"
        case .timeout: "timed out"
        case .protocolError(let m): "protocol error: \(m)"
        case .tls(let m): "TLS: \(m)"
        case .refused(let m): "refused: \(m)"
        case .wrongPhone: "this isn't the paired phone (its key doesn't match)"
        case .needsApproval: "the phone hasn't allowed USB debugging from this Mac yet"
        }
    }
}

/// Bytes in and out: plain TCP before STLS, TLS after.
protocol Channel: AnyObject, Sendable {
    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int // > 0, or throws
    func write(_ data: Data) throws
    func close()
    /// See `TCPSocket.setKeepalive`.
    func setKeepalive(busy: Bool)
}

extension Channel {
    func setKeepalive(busy: Bool) {}
    func readExactly(_ count: Int) throws -> Data {
        var data = Data(count: count)
        var filled = 0
        while filled < count {
            let n = try data.withUnsafeMutableBytes { raw in
                try read(into: UnsafeMutableRawBufferPointer(rebasing: raw[filled...]))
            }
            filled += n
        }
        return data
    }
}

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

    private static func keepalive(_ fd: Int32, busy: Bool) {
        var idle: Int32 = busy ? 10 : 900, interval: Int32 = busy ? 5 : 30, count: Int32 = 3
        let size = socklen_t(MemoryLayout<Int32>.size)
        setsockopt(fd, IPPROTO_TCP, TCP_KEEPALIVE, &idle, size)
        setsockopt(fd, IPPROTO_TCP, TCP_KEEPINTVL, &interval, size)
        setsockopt(fd, IPPROTO_TCP, TCP_KEEPCNT, &count, size)
    }
}

/// TLS 1.3 over the socket, as adb's wireless debugging uses it. An `SSL` may only be used by
/// one thread at a time, so every call is under `lock`; after the handshake the socket is
/// non-blocking and readers wait in poll() *outside* the lock, so writes never queue behind a
/// pending read.
final class TLSChannel: Channel, @unchecked Sendable {
    private let socket: TCPSocket
    private let ctx: OpaquePointer // SSL_CTX*
    private let ssl: OpaquePointer // SSL*
    private let lock = NSLock()
    /// SHA-256 of the phone's TLS public key, for pinning (stock adb accepts any).
    let peerKeySHA256: Data

    /// `expectedPeerKey`: the pinned SHA-256 of the phone's public key. A mismatch, or no
    /// certificate at all, fails before any adb data is exchanged. nil only when pinning for
    /// the first time (the caller then stores `peerKeySHA256`).
    init(socket: TCPSocket, key: AdbKey, expectedPeerKey: Data?, peekAfterHandshake: Bool = true) throws {
        self.socket = socket
        guard let ctx = SSL_CTX_new(TLS_method()) else { throw AdbError.tls("SSL_CTX_new") }
        SSL_CTX_set_min_proto_version(ctx, UInt16(TLS1_3_VERSION))
        SSL_CTX_set_max_proto_version(ctx, UInt16(TLS1_3_VERSION))
        guard SSL_CTX_use_certificate(ctx, key.certificate) == 1, SSL_CTX_use_PrivateKey(ctx, key.pkey) == 1 else {
            SSL_CTX_free(ctx)
            throw AdbError.tls("can't use the adb key")
        }
        // The phone's certificate is self-signed, so no CA check: it's pinned by key below.
        SSL_CTX_set_custom_verify(ctx, SSL_VERIFY_PEER) { _, _ in ssl_verify_ok }
        guard let ssl = SSL_new(ctx) else {
            SSL_CTX_free(ctx)
            throw AdbError.tls("SSL_new")
        }
        self.ctx = ctx
        self.ssl = ssl
        SSL_set_fd(ssl, Int32(socket.fd))
        guard SSL_connect(ssl) == 1 else {
            let reason = Self.errorString()
            SSL_free(ssl)
            SSL_CTX_free(ctx)
            throw AdbError.tls("handshake failed (\(reason))")
        }
        // TLS 1.3 doesn't tell the client its certificate was rejected; adbd speaks first on
        // success, so peek one byte, as adb does.
        var byte: UInt8 = 0
        guard !peekAfterHandshake || SSL_peek(ssl, &byte, 1) > 0 else {
            let reason = Self.errorString()
            SSL_free(ssl)
            SSL_CTX_free(ctx)
            throw AdbError.tls("the phone rejected this Mac's key (\(reason)). Pair again.")
        }
        let peerKey: Data? = SSL_get_peer_certificate(ssl).flatMap { peer in
            defer { X509_free(peer) }
            return publicKeySHA256(peer)
        }
        guard let peerKey, expectedPeerKey == nil || peerKey == expectedPeerKey else {
            SSL_free(ssl)
            SSL_CTX_free(ctx)
            throw AdbError.wrongPhone
        }
        peerKeySHA256 = peerKey
        let flags = fcntl(socket.fd, F_GETFL)
        _ = fcntl(socket.fd, F_SETFL, flags | O_NONBLOCK)
    }

    deinit {
        SSL_free(ssl)
        SSL_CTX_free(ctx)
    }

    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        while true {
            lock.lock()
            let n = SSL_read(ssl, buffer.baseAddress, Int32(min(buffer.count, Int(Int32.max))))
            let error = n > 0 ? SSL_ERROR_NONE : SSL_get_error(ssl, n)
            lock.unlock()
            if n > 0 { return Int(n) }
            switch error {
            case SSL_ERROR_WANT_READ: try wait(for: POLLIN)
            case SSL_ERROR_WANT_WRITE: try wait(for: POLLOUT)
            default: throw AdbError.closed
            }
        }
    }

    func write(_ data: Data) throws {
        try data.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                lock.lock()
                let n = SSL_write(ssl, raw.baseAddress! + sent, Int32(raw.count - sent))
                let error = n > 0 ? SSL_ERROR_NONE : SSL_get_error(ssl, n)
                lock.unlock()
                if n > 0 { sent += Int(n); continue }
                switch error {
                case SSL_ERROR_WANT_WRITE: try wait(for: POLLOUT)
                case SSL_ERROR_WANT_READ: try wait(for: POLLIN)
                default: throw AdbError.closed
                }
            }
        }
    }

    private func wait(for event: Int32) throws {
        var pfd = pollfd(fd: socket.fd, events: Int16(event), revents: 0)
        let r = poll(&pfd, 1, -1)
        if r < 0 && errno != EINTR { throw AdbError.closed }
        if pfd.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 && pfd.revents & Int16(POLLIN) == 0 { throw AdbError.closed }
    }

    /// RFC 5705 exporter (pairing mixes this into the SPAKE2 password).
    func exportKeyingMaterial(label: [UInt8], length: Int) -> Data? {
        var out = [UInt8](repeating: 0, count: length)
        let ok = lock.withLock {
            label.withUnsafeBufferPointer { l in
                l.withMemoryRebound(to: CChar.self) {
                    SSL_export_keying_material(ssl, &out, length, $0.baseAddress, l.count, nil, 0, 0)
                }
            }
        }
        return ok == 1 ? Data(out) : nil
    }

    func close() {
        lock.lock()
        SSL_shutdown(ssl)
        lock.unlock()
        socket.close()
    }

    func setKeepalive(busy: Bool) { socket.setKeepalive(busy: busy) }

    static func errorString() -> String {
        let code = ERR_get_error()
        guard code != 0 else { return "no details" }
        var buffer = [CChar](repeating: 0, count: 256)
        ERR_error_string_n(code, &buffer, buffer.count)
        return String(cString: buffer)
    }
}
