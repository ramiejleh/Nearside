import CoreMedia
import Foundation
import QuartzCore
import VideoToolbox

/// Hardware HEVC decoding with VideoToolbox. Input is Annex-B (as the phone's encoder emits);
/// output is NV12 video-range pixel buffers that Metal can sample. Not thread-safe: feed it from
/// one thread (the session's video reader).
public final class VideoDecoder: @unchecked Sendable {
    public struct Frame: @unchecked Sendable {
        public let image: CVPixelBuffer
        public let gen: UInt32
        public let ptsMicros: Int64
        public let receivedMicros: Int64
    }

    private var session: VTDecompressionSession?
    private var format: CMVideoFormatDescription?
    public private(set) var gen: UInt32 = 0
    /// Called on VideoToolbox's thread with each decoded frame.
    public var onFrame: (@Sendable (Frame) -> Void)?

    public init() {}

    deinit { invalidate() }

    public func invalidate() {
        if let session {
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            VTDecompressionSessionInvalidate(session)
        }
        session = nil
    }

    /// New parameter sets (first frame, or after a resize restarted the encoder). False if unusable.
    @discardableResult
    public func configure(parameterSets annexB: Data, gen: UInt32) -> Bool {
        let sets = Self.nalUnits(annexB).filter { (32...34).contains(Self.nalType($0)) }
        guard sets.count >= 3 else { return false }
        var description: CMVideoFormatDescription?
        let status = Self.withPointers(sets) { pointers, sizes in
            CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                allocator: nil, parameterSetCount: sets.count, parameterSetPointers: pointers,
                parameterSetSizes: sizes, nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &description)
        }
        guard status == noErr, let description else { return false }
        self.gen = gen
        if let session, VTDecompressionSessionCanAcceptFormatDescription(session, formatDescription: description) {
            format = description
            return true
        }
        invalidate()
        format = description
        let spec = [kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: true] as CFDictionary
        let attributes = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferMetalCompatibilityKey: true,
        ] as CFDictionary
        var created: VTDecompressionSession?
        guard VTDecompressionSessionCreate(allocator: nil, formatDescription: description, decoderSpecification: spec,
                                           imageBufferAttributes: attributes, outputCallback: nil,
                                           decompressionSessionOut: &created) == noErr, let created else { return false }
        VTSessionSetProperty(created, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        session = created
        return true
    }

    public func decode(annexB: Data, gen: UInt32, ptsMicros: Int64, receivedMicros: Int64) {
        guard gen == self.gen, let session, let format else { return }
        // Start codes → 4-byte lengths; parameter sets already live in the format description.
        var sample = Data(capacity: annexB.count + 16)
        for nal in Self.nalUnits(annexB) where !(32...34).contains(Self.nalType(nal)) {
            sample.appendBE(UInt32(nal.count))
            sample.append(nal)
        }
        guard !sample.isEmpty else { return }
        var block: CMBlockBuffer?
        let length = sample.count
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: length, blockAllocator: nil,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: length, flags: 0,
                                                 blockBufferOut: &block) == noErr, let block else { return }
        _ = sample.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: length)
        }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMTime(value: ptsMicros, timescale: 1_000_000),
                                        decodeTimeStamp: .invalid)
        var size = length
        var buffer: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1,
                                        sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1,
                                        sampleSizeArray: &size, sampleBufferOut: &buffer) == noErr, let buffer else { return }
        let onFrame = self.onFrame
        VTDecompressionSessionDecodeFrame(session, sampleBuffer: buffer, flags: [._EnableAsynchronousDecompression],
                                          infoFlagsOut: nil) { status, _, image, _, _ in
            guard status == noErr, let image else { return }
            onFrame?(Frame(image: image, gen: gen, ptsMicros: ptsMicros, receivedMicros: receivedMicros))
        }
    }

    static func nalType(_ nal: Data) -> Int { Int((nal.first ?? 0) >> 1 & 0x3f) }

    /// NAL units of an Annex-B byte stream (start codes 00 00 01 / 00 00 00 01 removed).
    static func nalUnits(_ data: Data) -> [Data] {
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

    private static func withPointers<R>(_ parts: [Data], _ body: ([UnsafePointer<UInt8>], [Int]) -> R) -> R {
        let copies = parts.map { d -> UnsafeMutablePointer<UInt8> in
            let p = UnsafeMutablePointer<UInt8>.allocate(capacity: d.count)
            d.copyBytes(to: p, count: d.count)
            return p
        }
        defer { copies.forEach { $0.deallocate() } }
        return body(copies.map { UnsafePointer($0) }, parts.map(\.count))
    }
}

/// Microseconds on the Mac's monotonic clock (CACurrentMediaTime's base).
public func monotonicMicros() -> Int64 { Int64(CACurrentMediaTime() * 1_000_000) }
