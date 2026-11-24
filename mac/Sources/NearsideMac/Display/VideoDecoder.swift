import CoreMedia
import Foundation
import NearsideCore
import VideoToolbox

/// Hardware HEVC (or H.264) decoding with VideoToolbox. Input is Annex-B (as the phone's encoder
/// emits); output is NV12 video-range pixel buffers that Metal can sample. Not thread-safe: feed it
/// from one thread (the session's video reader).
public final class VideoDecoder: VideoDecoding, @unchecked Sendable {
    /// The Mac asks for HEVC. Test hook: NEARSIDE_TEST_CODEC=h264 asks for H.264 instead (what a
    /// PC without hardware HEVC asks for), to check the phone's H.264 path from here.
    public static let preferredCodec: DisplayWire.Codec =
        ProcessInfo.processInfo.environment["NEARSIDE_TEST_CODEC"] == "h264" ? .h264 : .hevc

    public struct Frame: VideoFrame, @unchecked Sendable {
        public let image: CVPixelBuffer
        public let gen: UInt32
        public let ptsMicros: Int64
        public let receivedMicros: Int64

        public func isBlack() -> Bool { Self.isBlack(image) }

        /// 64 points of the luma plane, all at video black (limited range: 16) or below 24.
        static func isBlack(_ image: CVPixelBuffer) -> Bool {
            guard CVPixelBufferLockBaseAddress(image, .readOnly) == kCVReturnSuccess else { return false }
            defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
            let planar = CVPixelBufferIsPlanar(image)
            guard let base = planar ? CVPixelBufferGetBaseAddressOfPlane(image, 0) : CVPixelBufferGetBaseAddress(image) else { return false }
            let width = planar ? CVPixelBufferGetWidthOfPlane(image, 0) : CVPixelBufferGetWidth(image)
            let height = planar ? CVPixelBufferGetHeightOfPlane(image, 0) : CVPixelBufferGetHeight(image)
            let row = planar ? CVPixelBufferGetBytesPerRowOfPlane(image, 0) : CVPixelBufferGetBytesPerRow(image)
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            for i in 0..<8 { for j in 0..<8 {
                let x = width * (2 * i + 1) / 16, y = height * (2 * j + 1) / 16
                if bytes[y * row + x] >= 24 { return false }
            } }
            return true
        }
    }

    private var session: VTDecompressionSession?
    private var format: CMVideoFormatDescription?
    public private(set) var gen: UInt32 = 0
    /// Called on VideoToolbox's thread with each decoded frame.
    public var onFrame: (@Sendable (any VideoFrame) -> Void)?

    public let codec: DisplayWire.Codec

    public init(codec: DisplayWire.Codec = VideoDecoder.preferredCodec) { self.codec = codec }

    /// Parameter-set NAL types: VPS, SPS, PPS for HEVC; SPS, PPS for H.264.
    private var parameterTypes: ClosedRange<Int> { codec == .h264 ? 7...8 : 32...34 }

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
        let sets = AnnexB.nalUnits(annexB).filter { parameterTypes.contains(AnnexB.nalType($0, codec)) }
        guard sets.count >= parameterTypes.count else { return false }
        var description: CMVideoFormatDescription?
        let status = Self.withPointers(sets) { pointers, sizes in
            codec == .h264
                ? CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: nil, parameterSetCount: sets.count, parameterSetPointers: pointers,
                    parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &description)
                : CMVideoFormatDescriptionCreateFromHEVCParameterSets(
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
        // Start codes → 4-byte lengths, written straight into the block VideoToolbox decodes from
        // (one copy); parameter sets already live in the format description.
        var block: CMBlockBuffer?
        let codec = self.codec, parameterTypes = self.parameterTypes
        let length: Int = annexB.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            let nals = AnnexB.nalRanges(bytes).filter { !parameterTypes.contains(AnnexB.nalType(bytes[$0.lowerBound], codec)) }
            let length = nals.reduce(0) { $0 + 4 + $1.count }
            guard length > 0,
                  CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: length, blockAllocator: nil,
                                                     customBlockSource: nil, offsetToData: 0, dataLength: length,
                                                     flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr,
                  let block else { return 0 }
            var out: UnsafeMutablePointer<CChar>?
            guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: nil,
                                              dataPointerOut: &out) == noErr, let out else { return 0 }
            var at = UnsafeMutableRawPointer(out)
            for nal in nals {
                let n = UInt32(nal.count).bigEndian
                withUnsafeBytes(of: n) { at.copyMemory(from: $0.baseAddress!, byteCount: 4) }
                at.advanced(by: 4).copyMemory(from: bytes.baseAddress! + nal.lowerBound, byteCount: nal.count)
                at = at.advanced(by: 4 + nal.count)
            }
            return length
        }
        guard length > 0, let block else { return }
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

