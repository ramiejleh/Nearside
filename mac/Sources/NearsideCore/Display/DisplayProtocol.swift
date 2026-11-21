import CryptoKit
import Foundation

/// The phone-apps stream protocol (vault/phone-apps-plan.md; helper side: DisplayServer.kt).
/// Every packet: u8 type, u8 flags, u32 big-endian length, payload. Lengths from the wire are never
/// trusted: each message checks its minimum size, and packets over `maxPacket` end the stream.
/// An app in the phone window (a task on its display).
public struct PhoneTask: Equatable, Sendable, Identifiable {
    public let id: Int32
    public let package: String
}

public enum DisplayWire {
    static let hello: UInt8 = 0x01
    // Mac → phone (control)
    static let open: UInt8 = 0x10, resume: UInt8 = 0x11, touch: UInt8 = 0x12, resize: UInt8 = 0x13
    static let nav: UInt8 = 0x14, ping: UInt8 = 0x15, visibility: UInt8 = 0x16, close: UInt8 = 0x17
    static let sync: UInt8 = 0x18, scroll: UInt8 = 0x19, mouse: UInt8 = 0x1A
    static let key: UInt8 = 0x1B, text: UInt8 = 0x1C, layout: UInt8 = 0x1D, paste: UInt8 = 0x1E
    /// A video frame arrived (its pts): the phone measures how far behind the stream is.
    static let ack: UInt8 = 0x1F
    /// The helper reads control packets up to 1 MiB; a longer paste is cut.
    static let maxControlBody = 1024 * 1024 - 16
    // phone → Mac
    static let task: UInt8 = 0x20, taskGone: UInt8 = 0x21, pong: UInt8 = 0x22, error: UInt8 = 0x23
    static let thermal: UInt8 = 0x24, secure: UInt8 = 0x25, tasks: UInt8 = 0x26, snapshot: UInt8 = 0x27
    // Phone window, Mac → phone.
    static let recents: UInt8 = 0x41, taskFront: UInt8 = 0x42, taskRemove: UInt8 = 0x43, dock: UInt8 = 0x44
    /// Mac → phone: the picture went all black (1) or isn't any more (0).
    static let black: UInt8 = 0x40
    static let config: UInt8 = 0x30, frame: UInt8 = 0x31
    static let audioConfig: UInt8 = 0x32, audio: UInt8 = 0x33

    public enum Role: UInt8, Sendable { case control = 1, video = 2, audio = 3 }
    static let version: UInt16 = 1
    /// A 4K keyframe is far below this.
    public static let maxPacket = 16 * 1024 * 1024

    public enum TouchAction: UInt8, Sendable { case down = 0, up = 1, move = 2, cancel = 3 }
    /// A mouse pointer (not a finger): hovering, and the right button.
    public enum MouseAction: UInt8, Sendable { case hover = 0, exit = 1, secondaryDown = 2, secondaryUp = 3 }
    public enum GoneReason: UInt8, Sendable { case exited = 0, movedToPhone = 1 }

    /// What the phone sends.
    public enum Message: Equatable, Sendable {
        /// The helper's proof that it holds the token (first packet on every stream).
        case serverHello(proof: Data)
        case task(id: Int32, package: String)
        case taskGone(GoneReason)
        case pong(t0: UInt64, phoneMicros: UInt64)
        case error(code: UInt8, message: String)
        /// Quality is reduced (or back to normal) because the phone is warm.
        case thermal(reduced: Bool)
        /// An app window on the display blocks capture (it draws black), or no longer does.
        case secure(Bool)
        /// The phone window's apps, top first (task id, package).
        case tasks([PhoneTask])
        /// A task's last picture (JPEG).
        case snapshot(task: Int32, jpeg: Data)
        case config(gen: UInt32, width: Int, height: Int, parameterSets: Data)
        case frame(gen: UInt32, ptsMicros: Int64, encodedMicros: Int64, keyframe: Bool, data: Data)
        /// The audio stream's format (Opus).
        case audioConfig(sampleRate: Int, channels: Int)
        /// One Opus packet (20 ms).
        case audio(ptsMicros: Int64, data: Data)
    }

    // MARK: Encoding

    static func packet(_ type: UInt8, _ body: Data = Data()) -> Data {
        var d = Data([type, 0])
        d.appendBE(UInt32(body.count))
        d.append(body)
        return d
    }

    /// HELLO: "ATD1", u16 version, u8 role, 16-byte session id, 32-byte ticket, HMAC-SHA256 with
    /// the helper token over "nearside-display:<role>:<session hex>:<ticket hex>".
    static func hello(role: Role, session: Data, ticket: Data, token: String) -> Data {
        precondition(session.count == 16 && ticket.count == 32)
        let message = "nearside-display:\(role.rawValue):\(session.hexString):\(ticket.hexString)"
        let proof = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: Data(token.utf8)))
        var body = Data("ATD1".utf8)
        body.appendBE(version)
        body.append(role.rawValue)
        body.append(session)
        body.append(ticket)
        body.append(contentsOf: proof)
        return packet(hello, body)
    }

    /// What the helper must answer to HELLO: the same values under a server label.
    static func serverProof(role: Role, session: Data, ticket: Data, token: String) -> Data {
        let message = "nearside-display-server:\(role.rawValue):\(session.hexString):\(ticket.hexString)"
        return Data(HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: Data(token.utf8))))
    }

    static func open(width: Int, height: Int, dpi: Int, fps: Int, kbps: Int, target: String) -> Data {
        var b = Data()
        b.appendBE(UInt16(width)); b.appendBE(UInt16(height)); b.appendBE(UInt16(dpi))
        b.append(UInt8(fps)); b.appendBE(UInt32(kbps))
        b.append(Data(target.utf8))
        return packet(open, b)
    }

    /// x/y normalised to the video (a scroll-drag finger may go past the edges); `micros` is the
    /// Mac event time, so the phone spaces the events as they happened and flings at the right speed.
    static func touch(_ action: TouchAction, pointer: UInt8, gen: UInt32, x: Float, y: Float, micros: UInt64) -> Data {
        var b = Data([action.rawValue, pointer])
        b.appendBE(gen); b.appendBE(x.bitPattern); b.appendBE(y.bitPattern); b.appendBE(micros)
        return packet(touch, b)
    }

    /// A mouse wheel: h/v in wheel notches (Android's AXIS_HSCROLL/AXIS_VSCROLL, + = right/up).
    static func scroll(gen: UInt32, x: Float, y: Float, h: Float, v: Float) -> Data {
        var b = Data()
        b.appendBE(gen); b.appendBE(x.bitPattern); b.appendBE(y.bitPattern); b.appendBE(h.bitPattern); b.appendBE(v.bitPattern)
        return packet(scroll, b)
    }

    static func mouse(_ action: MouseAction, gen: UInt32, x: Float, y: Float) -> Data {
        var b = Data([action.rawValue])
        b.appendBE(gen); b.appendBE(x.bitPattern); b.appendBE(y.bitPattern)
        return packet(mouse, b)
    }

    static func resize(width: Int, height: Int, dpi: Int) -> Data {
        var b = Data()
        b.appendBE(UInt16(width)); b.appendBE(UInt16(height)); b.appendBE(UInt16(dpi))
        return packet(resize, b)
    }

    /// An Android key press: KEY{u16 key code, u32 meta state}.
    static func key(_ k: KeyMap.Key) -> Data {
        var b = Data()
        b.appendBE(k.code); b.appendBE(k.meta)
        return packet(key, b)
    }

    /// TEXT, LAYOUT, PASTE: UTF-8, cut at a character boundary to fit.
    static func utf8(_ type: UInt8, _ string: String) -> Data {
        var s = Substring(string)
        while s.utf8.count > maxControlBody { s = s.dropLast(max(1, s.count / 10)) }
        return packet(type, Data(s.utf8))
    }

    static func task(_ type: UInt8, _ id: Int32) -> Data {
        var b = Data(); b.appendBE(UInt32(bitPattern: id))
        return packet(type, b)
    }

    static func ack(ptsMicros: Int64) -> Data {
        var b = Data(); b.appendBE(UInt64(bitPattern: ptsMicros))
        return packet(ack, b)
    }

    static func ping(_ t0: UInt64) -> Data {
        var b = Data(); b.appendBE(t0)
        return packet(ping, b)
    }

    // MARK: Decoding

    /// Splits a byte stream into packets. Once `failed`, the stream must be closed.
    public struct Reader: Sendable {
        private var buffer = Data()
        public private(set) var failed = false
        public init() {}

        public mutating func feed(_ data: Data) -> [Message] {
            guard !failed else { return [] }
            buffer.append(data)
            var out: [Message] = []
            var offset = buffer.startIndex
            while buffer.endIndex - offset >= 6 {
                let length = Int(buffer.readBE(UInt32.self, at: offset + 2))
                guard length <= DisplayWire.maxPacket else {
                    failed = true
                    buffer = Data()
                    return out
                }
                guard buffer.endIndex - offset >= 6 + length else { break }
                let body = buffer.subdata(in: offset + 6..<offset + 6 + length)
                if let message = DisplayWire.parse(type: buffer[offset], body) { out.append(message) }
                offset += 6 + length
            }
            buffer.removeSubrange(buffer.startIndex..<offset)
            return out
        }
    }

    /// One message, or nil if it's unknown or too short to be what it claims.
    static func parse(type: UInt8, _ p: Data) -> Message? {
        let s = p.startIndex
        switch type {
        case hello where p.count == 32:
            return .serverHello(proof: p)
        case task where p.count >= 4:
            return .task(id: Int32(bitPattern: p.readBE(UInt32.self, at: s)),
                         package: String(decoding: p.suffix(from: s + 4), as: UTF8.self))
        case taskGone where p.count >= 1:
            return .taskGone(GoneReason(rawValue: p[s]) ?? .exited)
        case pong where p.count >= 16:
            return .pong(t0: p.readBE(UInt64.self, at: s), phoneMicros: p.readBE(UInt64.self, at: s + 8))
        case error where p.count >= 1:
            return .error(code: p[s], message: String(decoding: p.suffix(from: s + 1), as: UTF8.self))
        case tasks:
            guard let list = try? JSONSerialization.jsonObject(with: p) as? [[String: Any]] else { return nil }
            return .tasks(list.compactMap { e in
                guard let id = (e["id"] as? NSNumber)?.int32Value, let pkg = e["pkg"] as? String else { return nil }
                return PhoneTask(id: id, package: pkg)
            })
        case snapshot where p.count > 4:
            return .snapshot(task: Int32(bitPattern: p.readBE(UInt32.self, at: s)), jpeg: p.subdata(in: s + 4..<p.endIndex))
        case secure where p.count >= 1:
            return .secure(p[s] != 0)
        case thermal where p.count >= 1:
            return .thermal(reduced: p[s] != 0)
        case config where p.count >= 8:
            return .config(gen: p.readBE(UInt32.self, at: s), width: Int(p.readBE(UInt16.self, at: s + 4)),
                           height: Int(p.readBE(UInt16.self, at: s + 6)), parameterSets: p.subdata(in: s + 8..<p.endIndex))
        case frame where p.count >= 21:
            return .frame(gen: p.readBE(UInt32.self, at: s), ptsMicros: Int64(bitPattern: p.readBE(UInt64.self, at: s + 4)),
                          encodedMicros: Int64(bitPattern: p.readBE(UInt64.self, at: s + 12)),
                          keyframe: p[s + 20] != 0, data: p.subdata(in: s + 21..<p.endIndex))
        case audioConfig where p.count >= 5:
            let rate = Int(p.readBE(UInt32.self, at: s)), channels = Int(p[s + 4])
            guard (8000...96000).contains(rate), (1...2).contains(channels) else { return nil }
            return .audioConfig(sampleRate: rate, channels: channels)
        case audio where p.count > 8:
            return .audio(ptsMicros: Int64(bitPattern: p.readBE(UInt64.self, at: s)), data: p.subdata(in: s + 8..<p.endIndex))
        default:
            return nil
        }
    }
}

extension Data {
    mutating func appendBE<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }

    func readBE<T: FixedWidthInteger>(_: T.Type, at index: Int) -> T {
        var value: T = 0
        for i in 0..<MemoryLayout<T>.size { value = value << 8 | T(self[index + i]) }
        return value
    }
}
