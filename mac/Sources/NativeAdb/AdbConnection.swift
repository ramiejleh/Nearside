import Foundation

/// The adb wire protocol (AOSP adb.h / protocol.txt): 24-byte little-endian headers, streams
/// opened by name ("shell,v2,raw:…", "localabstract:…") and multiplexed over one connection.
struct Packet {
    static let cnxn: UInt32 = 0x4E58_4E43
    static let stls: UInt32 = 0x534C_5453
    static let auth: UInt32 = 0x4854_5541
    static let open: UInt32 = 0x4E45_504F
    static let okay: UInt32 = 0x5941_4B4F
    static let wrte: UInt32 = 0x4554_5257
    static let clse: UInt32 = 0x4553_4C43

    let command: UInt32
    let arg0: UInt32
    let arg1: UInt32
    let payload: Data

    func encoded() -> Data {
        var data = Data(capacity: 24 + payload.count)
        let checksum = payload.reduce(UInt32(0)) { $0 &+ UInt32($1) }
        for field in [command, arg0, arg1, UInt32(payload.count), checksum, command ^ 0xFFFF_FFFF] {
            withUnsafeBytes(of: field.littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(payload)
        return data
    }

    static func read(from channel: Channel, maxPayload: Int) throws -> Packet {
        let header = try channel.readExactly(24)
        func field(_ i: Int) -> UInt32 {
            header.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self)) }
        }
        let command = field(0), length = Int(field(3))
        guard field(5) == command ^ 0xFFFF_FFFF else { throw AdbError.protocolError("bad packet magic") }
        guard length <= maxPayload else { throw AdbError.protocolError("packet too large (\(length))") }
        let payload = length > 0 ? try channel.readExactly(length) : Data()
        return Packet(command: command, arg0: field(1), arg1: field(2), payload: payload)
    }
}

/// One wireless-debugging connection to a phone.
public final class AdbConnection: @unchecked Sendable {
    static let version: UInt32 = 0x0100_0001
    static let maxPayload = 1024 * 1024
    /// What we implement, as adb's "features" (no delayed_ack: we use simple per-write acks).
    static let features = "shell_v2,cmd,stat_v2,ls_v2,fixed_push_mkdir,abb_exec"

    /// e.g. "device::ro.product.name=caiman;ro.product.model=Pixel 9 Pro;…;features=…"
    public let banner: String
    /// SHA-256 of the phone's TLS public key: pin it to know it's really this phone.
    public let peerKeySHA256: Data
    let channel: Channel
    let peerMaxPayload: Int

    private let lock = NSLock()
    private var streams: [UInt32: AdbStream] = [:]
    private var nextID: UInt32 = 1
    private var dead = false

    /// Connects, upgrades to TLS with `key` and waits for the phone's CNXN. `expectedPeerKey`
    /// pins the phone (see TLSChannel); pass nil only to learn the key the first time.
    public static func connect(host: String, port: UInt16, key: AdbKey, expectedPeerKey: Data?,
                               timeout: TimeInterval = 10) throws -> AdbConnection {
        let socket = try TCPSocket(host: host, port: port, timeout: timeout)
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0) // handshake reads only; cleared below
        setsockopt(socket.fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        try socket.write(Packet(command: Packet.cnxn, arg0: version, arg1: UInt32(maxPayload),
                                payload: Data("host::features=\(features)".utf8)).encoded())
        let reply = try Packet.read(from: socket, maxPayload: 4096)
        guard reply.command == Packet.stls else {
            throw AdbError.protocolError(reply.command == Packet.auth
                ? "the phone wants legacy RSA auth (not wireless debugging)" : "expected STLS")
        }
        try socket.write(Packet(command: Packet.stls, arg0: 0x0100_0000, arg1: 0, payload: Data()).encoded())
        let tls = try TLSChannel(socket: socket, key: key, expectedPeerKey: expectedPeerKey)

        let hello = try Packet.read(from: tls, maxPayload: maxPayload)
        guard hello.command == Packet.cnxn else { throw AdbError.protocolError("expected CNXN after TLS") }
        tv = timeval(tv_sec: 0, tv_usec: 0)
        setsockopt(socket.fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        let connection = AdbConnection(channel: tls, banner: String(decoding: hello.payload, as: UTF8.self),
                                       peerMaxPayload: Int(hello.arg1), peerKeySHA256: tls.peerKeySHA256)
        connection.startReading()
        return connection
    }

    init(channel: Channel, banner: String, peerMaxPayload: Int, peerKeySHA256: Data) {
        self.channel = channel
        self.banner = banner
        self.peerMaxPayload = min(max(peerMaxPayload, 4096), Self.maxPayload)
        self.peerKeySHA256 = peerKeySHA256
    }

    /// A property from the banner, e.g. "ro.product.model".
    public func property(_ name: String) -> String? {
        guard let props = banner.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false).last else { return nil }
        for pair in props.split(separator: ";") where pair.hasPrefix("\(name)=") {
            return String(pair.dropFirst(name.count + 1))
        }
        return nil
    }

    public var isAlive: Bool { lock.withLock { !dead } }

    public func close() {
        channel.close()
    }

    /// Opens a stream to a service on the phone ("shell,v2,raw:ls", "localabstract:name", …).
    public func open(_ service: String, timeout: TimeInterval = 10) throws -> AdbStream {
        let stream: AdbStream = try lock.withLock {
            guard !dead else { throw AdbError.closed }
            let stream = AdbStream(connection: self, localID: nextID)
            streams[nextID] = stream
            nextID &+= 1
            if nextID == 0 { nextID = 1 }
            return stream
        }
        try send(Packet(command: Packet.open, arg0: stream.localID, arg1: 0, payload: Data((service + "\0").utf8)))
        try stream.waitOpened(timeout: timeout, service: service)
        return stream
    }

    func send(_ packet: Packet) throws {
        try channel.write(packet.encoded())
    }

    func forget(_ stream: AdbStream) {
        lock.withLock { _ = streams.removeValue(forKey: stream.localID) }
    }

    private func startReading() {
        let thread = Thread { [self] in
            while true {
                guard let packet = try? Packet.read(from: channel, maxPayload: Self.maxPayload) else { break }
                let stream = lock.withLock { streams[packet.arg1] }
                switch packet.command {
                case Packet.okay: stream?.received(okayFrom: packet.arg0)
                case Packet.wrte:
                    guard let stream else { continue }
                    stream.received(data: packet.payload)
                    try? send(Packet(command: Packet.okay, arg0: stream.localID, arg1: packet.arg0, payload: Data()))
                case Packet.clse: stream?.receivedClose()
                default: break
                }
            }
            let all: [AdbStream] = lock.withLock {
                dead = true
                defer { streams.removeAll() }
                return Array(streams.values)
            }
            all.forEach { $0.receivedClose() }
        }
        thread.name = "adb-reader"
        thread.start()
    }
}

/// One adb stream. Writes wait for the phone's OKAY (adb's flow control); reads block.
public final class AdbStream: @unchecked Sendable {
    let localID: UInt32
    private unowned let connection: AdbConnection
    private let condition = NSCondition()
    private var remoteID: UInt32 = 0
    private var opened = false
    private var closed = false
    private var awaitingOkay = false
    private var inbound = Data()

    init(connection: AdbConnection, localID: UInt32) {
        self.connection = connection
        self.localID = localID
    }

    func waitOpened(timeout: TimeInterval, service: String) throws {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while !opened && !closed {
            if !condition.wait(until: deadline) { throw AdbError.timeout }
        }
        if !opened { throw AdbError.refused(service) }
    }

    func received(okayFrom remote: UInt32) {
        condition.lock()
        if !opened {
            opened = true
            remoteID = remote
        } else {
            awaitingOkay = false
        }
        condition.broadcast()
        condition.unlock()
    }

    func received(data: Data) {
        condition.lock()
        inbound.append(data)
        condition.broadcast()
        condition.unlock()
    }

    func receivedClose() {
        condition.lock()
        closed = true
        condition.broadcast()
        condition.unlock()
        connection.forget(self)
    }

    /// Sends bytes, in chunks the phone accepts, each acknowledged before the next.
    public func write(_ data: Data, timeout: TimeInterval = 30) throws {
        var offset = 0
        while offset < data.count {
            let chunk = data.subdata(in: offset..<min(offset + connection.peerMaxPayload, data.count))
            let remote: UInt32 = try {
                condition.lock()
                defer { condition.unlock() }
                if closed { throw AdbError.closed }
                awaitingOkay = true
                return remoteID
            }()
            try connection.send(Packet(command: Packet.wrte, arg0: localID, arg1: remote, payload: chunk))
            condition.lock()
            let deadline = Date().addingTimeInterval(timeout)
            while awaitingOkay && !closed {
                if !condition.wait(until: deadline) {
                    condition.unlock()
                    throw AdbError.timeout
                }
            }
            let wasClosed = closed && awaitingOkay
            condition.unlock()
            if wasClosed { throw AdbError.closed }
            offset += chunk.count
        }
    }

    /// Whatever has arrived (waiting for at least one byte); nil once the stream is closed.
    public func read(timeout: TimeInterval? = nil) throws -> Data? {
        condition.lock()
        defer { condition.unlock() }
        let deadline = timeout.map { Date().addingTimeInterval($0) }
        while inbound.isEmpty && !closed {
            if let deadline {
                if !condition.wait(until: deadline) { throw AdbError.timeout }
            } else {
                condition.wait()
            }
        }
        if inbound.isEmpty { return nil }
        defer { inbound.removeAll(keepingCapacity: true) }
        return inbound
    }

    public func close() {
        let (shouldSend, remote): (Bool, UInt32) = {
            condition.lock()
            defer { condition.unlock() }
            let send = opened && !closed
            closed = true
            condition.broadcast()
            return (send, remoteID)
        }()
        if shouldSend { try? connection.send(Packet(command: Packet.clse, arg0: localID, arg1: remote, payload: Data())) }
        connection.forget(self)
    }
}

extension AdbConnection {
    public struct ShellResult: Sendable {
        public let exitCode: Int32
        public let stdout: Data
        public let stderr: Data
        public var ok: Bool { exitCode == 0 }
        public var output: String {
            String(decoding: stdout + stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// Runs a command with the shell v2 protocol, which reports the exit code
    /// (packets: 1-byte id — 1 stdout, 2 stderr, 3 exit — then a 4-byte LE length).
    public func shell(_ command: String, timeout: TimeInterval = 30) throws -> ShellResult {
        let stream = try open("shell,v2,raw:" + command)
        defer { stream.close() }
        let deadline = Date().addingTimeInterval(timeout)
        var buffer = Data(), out = Data(), err = Data()
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw AdbError.timeout }
            guard let chunk = try stream.read(timeout: remaining) else {
                throw AdbError.protocolError("shell closed without an exit code")
            }
            buffer.append(chunk)
            while buffer.count >= 5 {
                let id = buffer[buffer.startIndex]
                let length = buffer.withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 1, as: UInt32.self))) }
                guard buffer.count >= 5 + length else { break }
                let body = buffer.subdata(in: buffer.startIndex + 5..<buffer.startIndex + 5 + length)
                buffer.removeSubrange(buffer.startIndex..<buffer.startIndex + 5 + length)
                switch id {
                case 1: out.append(body)
                case 2: err.append(body)
                case 3: return ShellResult(exitCode: Int32(body.first ?? 255), stdout: out, stderr: err)
                default: break
                }
            }
        }
    }
}
