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
    /// The largest packet the phone may send us. Every stream shares the one connection, so a
    /// large video packet holds up audio and control behind it: 256 KiB at most.
    static let maxPayload = 256 * 1024
    /// What we implement, as adb's "features". With `delayed_ack` (adbd on Android 14+) each
    /// stream gets a byte window, so several writes are in flight instead of one per round trip.
    static let features = "shell_v2,cmd,stat_v2,ls_v2,fixed_push_mkdir,abb_exec,delayed_ack"
    /// Default receive window per stream (what the phone may send before we've read it).
    public static let defaultWindow = 256 * 1024

    /// e.g. "device::ro.product.name=caiman;ro.product.model=Pixel 9 Pro;…;features=…"
    public let banner: String
    /// SHA-256 of the phone's TLS public key: pin it to know it's really this phone.
    public let peerKeySHA256: Data
    let channel: Channel
    let peerMaxPayload: Int
    /// Both sides speak delayed_ack: windows in A_OPEN/OKAY instead of one OKAY per write.
    let delayedAck: Bool

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

    /// Over a USB cable: the phone checks this Mac's key with AUTH (no TLS). If the phone doesn't
    /// know the key yet it asks "Allow USB debugging?": with `waitForApproval` > 0 we offer the key
    /// and wait that long for the tap, otherwise fail with `.needsApproval`. There's nothing to pin
    /// on a cable (`peerKeySHA256` is empty): the caller checks it's the paired phone.
    public static func connectUSB(_ device: USB.Device, key: AdbKey, publicKey: String,
                                  waitForApproval: TimeInterval = 0) throws -> AdbConnection {
        let usb = try USB.open(device)
        do {
            try usb.write(Packet(command: Packet.cnxn, arg0: version, arg1: UInt32(maxPayload),
                                 payload: Data("host::features=\(features)".utf8)).encoded())
            var signed = false
            while true {
                let packet = try Self.readWithTimeout(usb, seconds: signed && waitForApproval > 0 ? waitForApproval : 10)
                switch packet.command {
                case Packet.cnxn:
                    let connection = AdbConnection(channel: usb, banner: String(decoding: packet.payload, as: UTF8.self),
                                                   peerMaxPayload: Int(packet.arg1), peerKeySHA256: Data(), overUSB: true)
                    connection.startReading()
                    return connection
                case Packet.auth where packet.arg0 == 1: // TOKEN
                    if !signed, let signature = key.signToken(packet.payload) {
                        signed = true
                        try usb.write(Packet(command: Packet.auth, arg0: 2, arg1: 0, payload: signature).encoded())
                    } else {
                        // The phone doesn't know this key: offer it (the phone then asks the user).
                        guard waitForApproval > 0 else { throw AdbError.needsApproval }
                        try usb.write(Packet(command: Packet.auth, arg0: 3, arg1: 0, payload: Data((publicKey + "\0").utf8)).encoded())
                    }
                default: throw AdbError.protocolError("unexpected packet during USB auth")
                }
            }
        } catch {
            usb.close()
            throw error
        }
    }

    /// The handshake's reads with a deadline (USB reads block until the phone sends something).
    private static func readWithTimeout(_ channel: Channel, seconds: TimeInterval) throws -> Packet {
        final class Box: @unchecked Sendable { var result: Result<Packet, Error>? } // written before `done`
        let done = DispatchSemaphore(value: 0), box = Box()
        Thread {
            box.result = Result { try Packet.read(from: channel, maxPayload: 4096) }
            done.signal()
        }.start()
        guard done.wait(timeout: .now() + seconds) == .success, let outcome = box.result else {
            channel.close() // ends the read
            throw AdbError.timeout
        }
        return try outcome.get()
    }

    public let overUSB: Bool

    init(channel: Channel, banner: String, peerMaxPayload: Int, peerKeySHA256: Data, overUSB: Bool = false) {
        self.overUSB = overUSB
        self.channel = channel
        self.banner = banner
        self.peerMaxPayload = min(max(peerMaxPayload, 4096), Self.maxPayload)
        self.peerKeySHA256 = peerKeySHA256
        let features = banner.split(separator: ";").first { $0.hasPrefix("features=") }?
            .dropFirst("features=".count).split(separator: ",") ?? []
        self.delayedAck = features.contains("delayed_ack")
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

    /// Frequent keepalive probes while phone-app windows are open, rare otherwise (they wake the phone).
    public func setKeepalive(busy: Bool) { channel.setKeepalive(busy: busy) }

    /// True when the Mac has moved off the network this connection was made on.
    public var localAddressGone: Bool { channel.localAddressGone }

    /// Opens a stream to a service on the phone ("shell,v2,raw:ls", "localabstract:name", …).
    /// `window` bounds how much the phone may send before we read it (latency-sensitive streams
    /// keep it small: a big window only hides queueing).
    public func open(_ service: String, window: Int = AdbConnection.defaultWindow,
                     timeout: TimeInterval = 10) throws -> AdbStream {
        let stream: AdbStream = try lock.withLock {
            guard !dead else { throw AdbError.closed }
            let stream = AdbStream(connection: self, localID: nextID, delayedAck: delayedAck)
            streams[nextID] = stream
            nextID &+= 1
            if nextID == 0 { nextID = 1 }
            return stream
        }
        try send(Packet(command: Packet.open, arg0: stream.localID, arg1: delayedAck ? UInt32(window) : 0,
                        payload: Data((service + "\0").utf8)))
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
                case Packet.okay: stream?.received(okayFrom: packet.arg0, payload: packet.payload)
                case Packet.wrte:
                    // Acknowledged once the reader has taken the data (see AdbStream.read), so a
                    // slow consumer slows the phone down instead of growing our buffer.
                    stream?.received(data: packet.payload)
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
        thread.qualityOfService = .userInteractive // phone-app video, input replies and sound pass here
        thread.start()
    }
}

/// One adb stream. Flow control both ways: with delayed_ack, writes go out while the phone's
/// byte window allows and we return bytes to it as we read; without it, one write in flight
/// (each waits for OKAY) and each received write is acknowledged when it's read.
public final class AdbStream: @unchecked Sendable {
    let localID: UInt32
    private unowned let connection: AdbConnection
    private let delayedAck: Bool
    private let condition = NSCondition()
    private var remoteID: UInt32 = 0
    private var opened = false
    private var closed = false
    private var awaitingOkay = false // legacy mode
    private var sendWindow = 0 // delayed_ack: bytes the phone will still accept
    private var inbound = Data()
    private var unackedWrites = 0 // legacy mode: received writes not yet acknowledged
    private var unackedBytes = 0 // delayed_ack: received bytes not yet returned to the phone

    init(connection: AdbConnection, localID: UInt32, delayedAck: Bool) {
        self.connection = connection
        self.localID = localID
        self.delayedAck = delayedAck
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

    func received(okayFrom remote: UInt32, payload: Data) {
        // delayed_ack: the first OKAY carries the phone's window, later ones bytes it consumed
        // (int32 LE; it may be negative).
        let bytes = payload.count == 4
            ? Int(Int32(littleEndian: payload.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })) : 0
        condition.lock()
        if !opened {
            opened = true
            remoteID = remote
            sendWindow = bytes
        } else if delayedAck {
            sendWindow += bytes
        } else {
            awaitingOkay = false
        }
        condition.broadcast()
        condition.unlock()
    }

    func received(data: Data) {
        condition.lock()
        inbound.append(data)
        if delayedAck { unackedBytes += data.count } else { unackedWrites += 1 }
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

    /// Sends bytes in chunks the phone accepts, as fast as its flow control allows.
    public func write(_ data: Data, timeout: TimeInterval = 30) throws {
        var offset = 0
        while offset < data.count {
            let chunk = data.subdata(in: offset..<min(offset + connection.peerMaxPayload, data.count))
            if delayedAck {
                let remote: UInt32 = try {
                    condition.lock()
                    defer { condition.unlock() }
                    let deadline = Date().addingTimeInterval(timeout)
                    while sendWindow <= 0 && !closed {
                        if !condition.wait(until: deadline) { throw AdbError.timeout }
                    }
                    if closed { throw AdbError.closed }
                    sendWindow -= chunk.count
                    return remoteID
                }()
                try connection.send(Packet(command: Packet.wrte, arg0: localID, arg1: remote, payload: chunk))
                offset += chunk.count
                continue
            }
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
        let data = inbound
        inbound = Data() // the caller owns `data` now (keeping its capacity would copy it)
        let (writes, bytes, remote) = (unackedWrites, unackedBytes, remoteID)
        unackedWrites = 0
        unackedBytes = 0
        // Tell the phone we've taken it (without holding the lock while sending).
        condition.unlock()
        if delayedAck {
            var count = Int32(bytes).littleEndian
            try? connection.send(Packet(command: Packet.okay, arg0: localID, arg1: remote,
                                        payload: Data(bytes: &count, count: 4)))
        } else {
            for _ in 0..<writes {
                try? connection.send(Packet(command: Packet.okay, arg0: localID, arg1: remote, payload: Data()))
            }
        }
        condition.lock()
        return data
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
