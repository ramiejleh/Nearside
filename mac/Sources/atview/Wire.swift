import Foundation
import NativeAdb
import QuartzCore

/// Packets of the Gate B probe protocol (see StreamProbe.kt): u8 type, u32 BE length, payload.
enum Wire {
    static let hello: UInt8 = 1, config: UInt8 = 2, frame: UInt8 = 3
    static let touch: UInt8 = 10, ping: UInt8 = 11, pong: UInt8 = 12, resize: UInt8 = 13, bulk: UInt8 = 20

    static func packet(_ type: UInt8, _ body: Data) -> Data {
        var d = Data([type])
        d.appendBE(UInt32(body.count))
        d.append(body)
        return d
    }

    /// Splits a byte stream into packets; keeps partial data for the next call.
    struct Reader {
        /// Largest packet accepted (a 4K keyframe is well under this).
        static let maxPacket = 16 * 1024 * 1024
        private var buffer = Data()
        private(set) var overflowed = false
        mutating func feed(_ data: Data) -> [(UInt8, Data)] {
            guard !overflowed else { return [] }
            buffer.append(data)
            var out: [(UInt8, Data)] = []
            var offset = buffer.startIndex
            while buffer.endIndex - offset >= 5 {
                let length = Int(buffer.readBE(UInt32.self, at: offset + 1))
                guard length <= Self.maxPacket else { overflowed = true; buffer = Data(); return out }
                guard buffer.endIndex - offset >= 5 + length else { break }
                out.append((buffer[offset], buffer.subdata(in: offset + 5..<offset + 5 + length)))
                offset += 5 + length
            }
            buffer.removeSubrange(buffer.startIndex..<offset)
            return out
        }
    }
}

extension Data {
    mutating func appendBE<T: FixedWidthInteger>(_ v: T) {
        Swift.withUnsafeBytes(of: v.bigEndian) { append(contentsOf: $0) }
    }

    mutating func appendBE(_ v: Float) { appendBE(v.bitPattern) }

    func readBE<T: FixedWidthInteger>(_: T.Type, at index: Int) -> T {
        var v: T = 0
        for i in 0..<MemoryLayout<T>.size { v = v << 8 | T(self[index + i]) }
        return v
    }
}

/// Microseconds on the Mac's monotonic clock (the same base as CACurrentMediaTime / presentedTime).
func macMicros() -> Int64 {
    Int64(CACurrentMediaTime() * 1_000_000)
}

/// Percentile of a sample set (p in 0…100).
func percentile(_ values: [Double], _ p: Double) -> Double {
    guard !values.isEmpty else { return .nan }
    let sorted = values.sorted()
    return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p / 100 + 0.5))]
}

/// Clock offset between phone and Mac from ping/pong: keeps the lowest-RTT sample of a window.
final class ClockSync {
    private let lock = NSLock()
    private var samples: [(rtt: Int64, offset: Int64)] = []
    private(set) var rtts: [Double] = []

    func add(t0: Int64, phone: Int64, t1: Int64) {
        lock.withLock {
            let rtt = t1 - t0
            samples.append((rtt, phone - (t0 + t1) / 2))
            if samples.count > 40 { samples.removeFirst() }
            rtts.append(Double(rtt) / 1000)
        }
    }

    /// phone µs − mac µs, or nil before the first pong.
    var offset: Int64? { lock.withLock { samples.min { $0.rtt < $1.rtt }?.offset } }

    func takeRTTs() -> [Double] { lock.withLock { defer { rtts.removeAll() }; return rtts } }
}
