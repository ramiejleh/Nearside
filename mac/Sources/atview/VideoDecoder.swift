import CoreMedia
import Foundation
import VideoToolbox

/// Hardware HEVC decoding with VideoToolbox. Input is Annex-B (as the phone's encoder emits);
/// output is NV12 video-range pixel buffers that Metal can sample.
final class VideoDecoder {
    struct Frame {
        let image: CVPixelBuffer
        let ptsUs: Int64
        let gen: UInt32
        let receivedUs: Int64
        let decodedUs: Int64
    }

    private var session: VTDecompressionSession?
    private var format: CMVideoFormatDescription?
    private(set) var gen: UInt32 = 0
    var onFrame: ((Frame) -> Void)?

    /// New parameter sets (first frame, or after a resize restarted the encoder).
    func configure(annexB: Data, gen: UInt32) {
        let sets = Self.nalUnits(annexB).filter { (32...34).contains(($0.first ?? 0) >> 1 & 0x3f) }
        guard sets.count >= 3 else { return }
        var description: CMVideoFormatDescription?
        let status: OSStatus = sets.withPointers { pointers, sizes in
            CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                allocator: nil, parameterSetCount: sets.count, parameterSetPointers: pointers,
                parameterSetSizes: sizes, nalUnitHeaderLength: 4, extensions: nil,
                formatDescriptionOut: &description)
        }
        guard status == noErr, let description else { return print("format description failed: \(status)") }
        self.gen = gen
        if let session, VTDecompressionSessionCanAcceptFormatDescription(session, formatDescription: description) {
            format = description
            return
        }
        if let session {
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            VTDecompressionSessionInvalidate(session)
        }
        format = description
        let spec = [kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: true] as CFDictionary
        let attrs = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferMetalCompatibilityKey: true,
        ] as CFDictionary
        var newSession: VTDecompressionSession?
        let created = VTDecompressionSessionCreate(allocator: nil, formatDescription: description,
                                                   decoderSpecification: spec, imageBufferAttributes: attrs,
                                                   outputCallback: nil, decompressionSessionOut: &newSession)
        guard created == noErr, let newSession else { return print("decoder session failed: \(created)") }
        VTSessionSetProperty(newSession, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        session = newSession
    }

    func decode(annexB: Data, ptsUs: Int64, gen: UInt32, receivedUs: Int64) {
        guard gen == self.gen, let session, let format else { return }
        // Annex-B start codes → 4-byte lengths; parameter sets are already in the format.
        var avcc = Data(capacity: annexB.count + 16)
        for nal in Self.nalUnits(annexB) where !(32...34).contains((nal.first ?? 0) >> 1 & 0x3f) {
            avcc.appendBE(UInt32(nal.count))
            avcc.append(nal)
        }
        guard !avcc.isEmpty else { return }
        var block: CMBlockBuffer?
        let length = avcc.count
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: length,
                                                 blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
                                                 dataLength: length, flags: 0, blockBufferOut: &block) == noErr,
              let block else { return }
        _ = avcc.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block,
                                                                  offsetIntoDestination: 0, dataLength: length) }
        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: CMTime(value: ptsUs, timescale: 1_000_000),
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        var size = length
        guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format,
                                        sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                        sampleSizeEntryCount: 1, sampleSizeArray: &size,
                                        sampleBufferOut: &sample) == noErr, let sample else { return }
        let frameGen = gen
        VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample,
                                          flags: [._EnableAsynchronousDecompression], infoFlagsOut: nil) {
            [weak self] status, _, image, _, _ in
            guard status == noErr, let image else { return }
            self?.onFrame?(Frame(image: image, ptsUs: ptsUs, gen: frameGen, receivedUs: receivedUs,
                                 decodedUs: macMicros()))
        }
    }

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
                    units.append(Data(bytes[start..<end]))
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

private extension Array where Element == Data {
    /// Calls body with stable pointers to every element's bytes.
    func withPointers<R>(_ body: ([UnsafePointer<UInt8>], [Int]) -> R) -> R {
        let copies = map { d -> UnsafeMutablePointer<UInt8> in
            let p = UnsafeMutablePointer<UInt8>.allocate(capacity: d.count)
            d.copyBytes(to: p, count: d.count)
            return p
        }
        defer { copies.forEach { $0.deallocate() } }
        return body(copies.map { UnsafePointer($0) }, map(\.count))
    }
}
