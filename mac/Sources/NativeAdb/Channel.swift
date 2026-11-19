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

    public var description: String {
        switch self {
        case .connect(let m): "can't connect: \(m)"
        case .closed: "connection closed"
        case .timeout: "timed out"
        case .protocolError(let m): "protocol error: \(m)"
        case .tls(let m): "TLS: \(m)"
        case .refused(let m): "refused: \(m)"
        }
    }
}

/// Bytes in and out: plain TCP before STLS, TLS after.
protocol Channel: AnyObject, Sendable {
    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int // > 0, or throws
    func write(_ data: Data) throws
    func close()
}

extension Channel {
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
    let peerKeySHA256: Data?

    init(socket: TCPSocket, key: AdbKey) throws {
        self.socket = socket
        guard let ctx = SSL_CTX_new(TLS_method()) else { throw AdbError.tls("SSL_CTX_new") }
        SSL_CTX_set_min_proto_version(ctx, UInt16(TLS1_3_VERSION))
        SSL_CTX_set_max_proto_version(ctx, UInt16(TLS1_3_VERSION))
        guard SSL_CTX_use_certificate(ctx, key.certificate) == 1, SSL_CTX_use_PrivateKey(ctx, key.pkey) == 1 else {
            SSL_CTX_free(ctx)
            throw AdbError.tls("can't use the adb key")
        }
        // Accept the phone's self-signed certificate here; the caller pins its key instead.
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
        guard SSL_peek(ssl, &byte, 1) > 0 else {
            let reason = Self.errorString()
            SSL_free(ssl)
            SSL_CTX_free(ctx)
            throw AdbError.tls("the phone rejected this Mac's key (\(reason)). Pair again.")
        }
        if let peer = SSL_get_peer_certificate(ssl) {
            peerKeySHA256 = publicKeySHA256(peer)
            X509_free(peer)
        } else {
            peerKeySHA256 = nil
        }
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

    func close() {
        lock.lock()
        SSL_shutdown(ssl)
        lock.unlock()
        socket.close()
    }

    static func errorString() -> String {
        let code = ERR_get_error()
        guard code != 0 else { return "no details" }
        var buffer = [CChar](repeating: 0, count: 256)
        ERR_error_string_n(code, &buffer, buffer.count)
        return String(cString: buffer)
    }
}
