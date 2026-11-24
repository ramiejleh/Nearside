import AudioToolbox
import Foundation
@testable import NearsideMac
import Testing

struct OpusTests {
    /// Opus made by the Mac's encoder (as the phone's would be) decodes back to the same tone.
    @Test func decodesOpus() throws {
        let rate = 48_000, channels = 2, frames = 960
        var pcm = OpusDecoder.pcmFormat(sampleRate: rate, channels: channels)
        var opus = AudioStreamBasicDescription(mSampleRate: Double(rate), mFormatID: kAudioFormatOpus, mFormatFlags: 0, mBytesPerPacket: 0,
                                               mFramesPerPacket: UInt32(frames), mBytesPerFrame: 0, mChannelsPerFrame: UInt32(channels),
                                               mBitsPerChannel: 0, mReserved: 0)
        var encoder: AudioConverterRef?
        #expect(AudioConverterNew(&pcm, &opus, &encoder) == noErr)
        let decoder = try #require(OpusDecoder(sampleRate: rate, channels: channels))
        final class Source { var samples: [Float] = []; var offset = 0 }
        let source = Source()
        for i in 0..<(frames * 20) { // 400 ms of 440 Hz at half scale
            let v = Float(sin(Double(i) * 2 * .pi * 440 / Double(rate))) * 0.5
            source.samples += [v, v]
        }
        var decoded: [Float] = []
        for _ in 0..<20 {
            var packetSize: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            AudioConverterGetProperty(encoder!, kAudioConverterPropertyMaximumOutputPacketSize, &size, &packetSize)
            var out = [UInt8](repeating: 0, count: Int(max(packetSize, 1500)))
            var description = AudioStreamPacketDescription()
            var packets: UInt32 = 1
            let status = out.withUnsafeMutableBytes { raw -> OSStatus in
                var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: UInt32(channels), mDataByteSize: UInt32(raw.count), mData: raw.baseAddress))
                return AudioConverterFillComplexBuffer(encoder!, { _, n, data, _, user in
                    let source = Unmanaged<Source>.fromOpaque(user!).takeUnretainedValue()
                    let want = min(Int(n.pointee), (source.samples.count - source.offset) / 2)
                    n.pointee = UInt32(want)
                    source.samples.withUnsafeMutableBufferPointer { b in
                        data.pointee.mBuffers.mData = UnsafeMutableRawPointer(b.baseAddress! + source.offset)
                    }
                    data.pointee.mBuffers.mDataByteSize = UInt32(want * 8)
                    data.pointee.mBuffers.mNumberChannels = 2
                    source.offset += want * 2
                    return noErr
                }, Unmanaged.passUnretained(source).toOpaque(), &packets, &list, &description)
            }
            guard status == noErr, packets == 1 else { break }
            let packet = Data(out[Int(description.mStartOffset)..<Int(description.mStartOffset) + Int(description.mDataByteSize)])
            decoded += decoder.decode(packet) ?? []
        }
        #expect(decoded.count >= frames * channels * 10)
        let peak = decoded.suffix(frames * 4).map(abs).max() ?? 0
        #expect(peak > 0.35 && peak < 0.65) // the tone, roughly at its level
    }
}
