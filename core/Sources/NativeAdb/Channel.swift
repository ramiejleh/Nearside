import CNIOBoringSSL
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
    case usbInUse        // USB: another program (adb's server, Android Studio) holds the interface

    /// A USB handshake that may work on a second try: the previous program's leftovers in the
    /// pipe, or the phone slow to answer.
    public var isTransientOnUSB: Bool {
        switch self {
        case .protocolError, .timeout, .closed: true
        default: false
        }
    }

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
        case .usbInUse: "the phone's USB connection is in use by another program (quit Android Studio, or run `adb kill-server`)"
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
    /// See `TCPSocket.localAddressGone`.
    var localAddressGone: Bool { get }
}

extension Channel {
    func setKeepalive(busy: Bool) {}
    var localAddressGone: Bool { false } // USB: no network address
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
        SSL_set_fd(ssl, socket.sslHandle)
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
        socket.setNonBlocking()
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
            case SSL_ERROR_WANT_READ: try socket.wait(readable: true)
            case SSL_ERROR_WANT_WRITE: try socket.wait(readable: false)
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
                case SSL_ERROR_WANT_WRITE: try socket.wait(readable: false)
                case SSL_ERROR_WANT_READ: try socket.wait(readable: true)
                default: throw AdbError.closed
                }
            }
        }
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

    var localAddressGone: Bool { socket.localAddressGone }

    static func errorString() -> String {
        let code = ERR_get_error()
        guard code != 0 else { return "no details" }
        var buffer = [CChar](repeating: 0, count: 256)
        ERR_error_string_n(code, &buffer, buffer.count)
        return String(cString: buffer)
    }
}
