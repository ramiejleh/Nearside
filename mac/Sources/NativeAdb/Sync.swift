import Foundation

/// adb's file sync protocol (AOSP file_sync_protocol.h, v1 messages) and streamed installs.
extension AdbConnection {
    private static func id(_ s: String) -> UInt32 {
        let b = Array(s.utf8)
        return UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24
    }

    private static let send = id("SEND"), recv = id("RECV"), data = id("DATA"), done = id("DONE")
    private static let okay = id("OKAY"), fail = id("FAIL"), quit = id("QUIT")
    private static let chunk = 64 * 1024 // SYNC_DATA_MAX

    private static func header(_ id: UInt32, _ value: UInt32) -> Data {
        var d = Data(capacity: 8)
        withUnsafeBytes(of: id.littleEndian) { d.append(contentsOf: $0) }
        withUnsafeBytes(of: value.littleEndian) { d.append(contentsOf: $0) }
        return d
    }

    /// Copies a local file to `remote`, with its modification time set to `modified`.
    public func push(_ local: URL, to remote: String, mode: UInt32 = 0o100644, modified: Date = Date()) throws {
        guard let input = InputStream(url: local) else { throw AdbError.protocolError("can't read \(local.path)") }
        input.open()
        defer { input.close() }
        let stream = try open("sync:")
        defer { stream.close() }
        let target = Data("\(remote),\(mode)".utf8)
        guard target.count <= 1024 else { throw AdbError.protocolError("path too long") }

        // Batch several DATA frames per adb packet: each packet waits for an OKAY.
        var batch = Self.header(Self.send, UInt32(target.count)) + target
        var buffer = [UInt8](repeating: 0, count: Self.chunk)
        while true {
            let n = input.read(&buffer, maxLength: Self.chunk)
            if n < 0 { throw AdbError.protocolError("read error on \(local.lastPathComponent)") }
            if n == 0 { break }
            batch.append(Self.header(Self.data, UInt32(n)))
            batch.append(contentsOf: buffer[0..<n])
            if batch.count >= peerMaxPayload - Self.chunk - 8 {
                try stream.write(batch)
                batch.removeAll(keepingCapacity: true)
            }
        }
        batch.append(Self.header(Self.done, UInt32(max(0, modified.timeIntervalSince1970))))
        try stream.write(batch)
        let status = try Self.readSyncHeader(stream)
        if status.id == Self.fail { throw AdbError.protocolError(try Self.readString(stream, status.value)) }
        guard status.id == Self.okay else { throw AdbError.protocolError("unexpected push reply") }
        try? stream.write(Self.header(Self.quit, 0))
    }

    /// Copies `remote` from the phone to a local file.
    public func pull(_ remote: String, to local: URL) throws {
        let stream = try open("sync:")
        defer { stream.close() }
        let path = Data(remote.utf8)
        try stream.write(Self.header(Self.recv, UInt32(path.count)) + path)
        FileManager.default.createFile(atPath: local.path, contents: nil)
        let out = try FileHandle(forWritingTo: local)
        defer { try? out.close() }
        var reader = SyncReader(stream: stream)
        do {
            while true {
                let h = try reader.header()
                switch h.id {
                case Self.data: try out.write(contentsOf: try reader.bytes(Int(h.value)))
                case Self.done:
                    try? stream.write(Self.header(Self.quit, 0))
                    return
                case Self.fail: throw AdbError.protocolError(String(decoding: try reader.bytes(Int(h.value)), as: UTF8.self))
                default: throw AdbError.protocolError("unexpected pull reply")
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: local)
            throw error
        }
    }

    /// Streams an APK into the package manager ("adb install -r"). Returns its last line.
    @discardableResult
    public func install(_ apk: URL, timeout: TimeInterval = 180) throws -> String {
        let size = (try FileManager.default.attributesOfItem(atPath: apk.path)[.size] as? NSNumber)?.intValue ?? 0
        guard size > 0 else { throw AdbError.protocolError("empty APK") }
        let stream = try open("exec:cmd package install -r -S \(size)")
        defer { stream.close() }
        guard let input = InputStream(url: apk) else { throw AdbError.protocolError("can't read the APK") }
        input.open()
        defer { input.close() }
        var buffer = [UInt8](repeating: 0, count: peerMaxPayload)
        while true {
            let n = input.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            try stream.write(Data(buffer[0..<n]))
        }
        var output = Data()
        let deadline = Date().addingTimeInterval(timeout)
        while let more = try stream.read(timeout: max(1, deadline.timeIntervalSinceNow)) { output.append(more) }
        let text = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("Success") else { throw AdbError.protocolError(text.isEmpty ? "install failed" : text) }
        return text
    }

    private static func readSyncHeader(_ stream: AdbStream) throws -> (id: UInt32, value: UInt32) {
        var reader = SyncReader(stream: stream)
        return try reader.header()
    }

    private static func readString(_ stream: AdbStream, _ length: UInt32) throws -> String {
        var reader = SyncReader(stream: stream)
        return String(decoding: try reader.bytes(Int(length)), as: UTF8.self)
    }
}

/// Reads exact byte counts off a stream that delivers arbitrary chunks.
struct SyncReader {
    let stream: AdbStream
    var pending = Data()

    mutating func bytes(_ count: Int) throws -> Data {
        while pending.count < count {
            guard let more = try stream.read(timeout: 60) else { throw AdbError.closed }
            pending.append(more)
        }
        let out = pending.prefix(count)
        pending.removeFirst(count)
        return Data(out)
    }

    mutating func header() throws -> (id: UInt32, value: UInt32) {
        let h = try bytes(8)
        return h.withUnsafeBytes {
            (UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self)),
             UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self)))
        }
    }
}
