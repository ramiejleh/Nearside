import Foundation

/// NAL units in an Annex-B byte stream (start codes 00 00 01 / 00 00 00 01), as the phone's encoder emits.
public enum AnnexB {
    public static func nalType(_ nal: Data, _ codec: DisplayWire.Codec = .hevc) -> Int { nalType(nal.first ?? 0, codec) }
    public static func nalType(_ header: UInt8, _ codec: DisplayWire.Codec) -> Int {
        codec == .h264 ? Int(header & 0x1f) : Int(header >> 1 & 0x3f)
    }

    /// Where each NAL unit of an Annex-B byte stream is (start codes left out), without copying.
    public static func nalRanges(_ bytes: UnsafeBufferPointer<UInt8>) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var i = 0, start = -1
        while i + 2 < bytes.count {
            if bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 1 {
                if start >= 0 {
                    var end = i
                    if end > start, bytes[end - 1] == 0 { end -= 1 }
                    if end > start { ranges.append(start..<end) }
                }
                i += 3
                start = i
            } else {
                i += 1
            }
        }
        if start >= 0, start < bytes.count { ranges.append(start..<bytes.count) }
        return ranges
    }

    /// NAL units of an Annex-B byte stream (start codes 00 00 01 / 00 00 00 01 removed).
    public static func nalUnits(_ data: Data) -> [Data] {
        var units: [Data] = []
        let bytes = [UInt8](data)
        var i = 0, start = -1
        while i + 2 < bytes.count {
            if bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 1 {
                if start >= 0 {
                    var end = i
                    if end > start, bytes[end - 1] == 0 { end -= 1 }
                    if end > start { units.append(Data(bytes[start..<end])) }
                }
                i += 3
                start = i
            } else {
                i += 1
            }
        }
        if start >= 0, start < bytes.count { units.append(Data(bytes[start...])) }
        return units
    }
}
