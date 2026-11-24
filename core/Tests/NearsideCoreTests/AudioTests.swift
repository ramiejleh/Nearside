@testable import NearsideCore
import Foundation
import Testing

struct AudioTests {
    @Test func parsesAudioMessages() {
        var config = Data(); config.appendBE(UInt32(48_000)); config.append(2)
        var audio = Data(); audio.appendBE(UInt64(1_234)); audio.append(contentsOf: [0xFC, 1, 2])
        var bad = Data(); bad.appendBE(UInt32(48_000)); bad.append(7) // 7 channels: refused
        var reader = DisplayWire.Reader()
        let messages = reader.feed(DisplayWire.packet(DisplayWire.audioConfig, config) + DisplayWire.packet(DisplayWire.audio, audio)
                                   + DisplayWire.packet(DisplayWire.audioConfig, bad) + DisplayWire.packet(DisplayWire.audio, Data([1])))
        #expect(messages == [.audioConfig(sampleRate: 48_000, channels: 2), .audio(ptsMicros: 1_234, data: Data([0xFC, 1, 2]))])
    }

    @Test func jitterBufferWaitsThenPlaysThenRefills() {
        var buffer = JitterBuffer(channels: 1, minTarget: 4, maxTarget: 8, slack: 6, step: 2, calm: 100, window: 1000)
        var out = [Float](repeating: 9, count: 3)
        buffer.write([1, 2, 3])
        out.withUnsafeMutableBufferPointer { buffer.read(into: $0.baseAddress!, frames: 3) }
        #expect(out == [0, 0, 0]) // not enough yet: silence
        buffer.write([4])
        out.withUnsafeMutableBufferPointer { buffer.read(into: $0.baseAddress!, frames: 3) }
        #expect(out == [1, 2, 3])
        out.withUnsafeMutableBufferPointer { buffer.read(into: $0.baseAddress!, frames: 3) }
        #expect(out == [4, 0, 0]) // ran dry
        #expect(buffer.underruns == 1 && !buffer.playing)
        #expect(buffer.target == 6) // grew by a step
    }

    @Test func silenceFromThePhoneIsNotAnUnderrun() {
        var buffer = JitterBuffer(channels: 1, minTarget: 4, maxTarget: 8, slack: 6, step: 2, calm: 100, window: 1000)
        var out = [Float](repeating: 9, count: 3)
        buffer.write([1, 2, 3, 4])
        buffer.endOfSound() // the phone: silence follows
        out.withUnsafeMutableBufferPointer { buffer.read(into: $0.baseAddress!, frames: 3) }
        out.withUnsafeMutableBufferPointer { buffer.read(into: $0.baseAddress!, frames: 3) }
        #expect(out == [4, 0, 0]) // played out, then quiet
        #expect(buffer.underruns == 0 && buffer.target == 4 && !buffer.playing)
        // Sound again: a real dropout after it counts as before.
        buffer.write([5, 6, 7, 8])
        out.withUnsafeMutableBufferPointer { buffer.read(into: $0.baseAddress!, frames: 3) }
        out.withUnsafeMutableBufferPointer { buffer.read(into: $0.baseAddress!, frames: 3) }
        #expect(buffer.underruns == 1)
    }

    @Test func jitterTargetGrowsOnUnderrunsAndShrinksWhenCalm() {
        var buffer = JitterBuffer(channels: 1, minTarget: 4, maxTarget: 8, slack: 4, step: 4, calm: 12, window: 1000)
        var out = [Float](repeating: 0, count: 4)
        func read() { out.withUnsafeMutableBufferPointer { buffer.read(into: $0.baseAddress!, frames: 4) } }
        buffer.write([1, 1, 1, 1]); read(); read()        // dry → target 8
        buffer.write([1, 1, 1, 1]); read()                // under the new target: waits (silence, no underrun)
        #expect(buffer.target == 8 && buffer.underruns == 1 && !buffer.playing)
        buffer.write([1, 1, 1, 1]); read(); read(); read() // 8 in: plays, then dry again → stays at max 8
        #expect(buffer.target == 8 && buffer.underruns == 2)
        buffer.write([Float](repeating: 1, count: 12))     // ≥ 8: plays
        read(); read(); read()                             // 12 frames without running dry: calm
        #expect(buffer.target == 6)
    }

    @Test func jitterBufferTrimsABacklogThatWasNeverNeeded() {
        var buffer = JitterBuffer(channels: 1, minTarget: 4, maxTarget: 8, slack: 20, step: 4, calm: 1000, window: 8)
        buffer.write([Float](repeating: 1, count: 16)) // a burst: 16 in, target 4
        var out = [Float](repeating: 0, count: 4)
        for _ in 0..<2 {                                // a window of reading 4 while 4 arrive
            out.withUnsafeMutableBufferPointer { buffer.read(into: $0.baseAddress!, frames: 4) }
            buffer.write([1, 1, 1, 1])
        }
        #expect(buffer.buffered == 4 + 4 && buffer.dropped == 8) // trimmed 12 → 4 (then 4 arrived)
    }

    @Test func jitterBufferDropsTheOldestWhenBehind() {
        var buffer = JitterBuffer(channels: 2, minTarget: 2, maxTarget: 4, slack: 2, step: 2, calm: 100, window: 1000)
        buffer.write([1, 1, 2, 2, 3, 3, 4, 4, 5, 5]) // 5 frames > limit 4 → back to 2
        #expect(buffer.buffered == 2 && buffer.dropped == 3)
        var out = [Float](repeating: 0, count: 4)
        out.withUnsafeMutableBufferPointer { buffer.read(into: $0.baseAddress!, frames: 2) }
        #expect(out == [4, 4, 5, 5])
    }
}

@Suite struct MicWireTests {
    @Test func recordingStateAndMicPackets() {
        var reader = DisplayWire.Reader()
        let messages = reader.feed(DisplayWire.packet(DisplayWire.mic, Data([1])) + DisplayWire.packet(DisplayWire.mic, Data([0]))
                                   + DisplayWire.packet(DisplayWire.mic)) // empty: ignored
        #expect(messages == [.mic(true), .mic(false)])
        let pcm = Data(repeating: 7, count: 1920)
        let packet = DisplayWire.micAudioPacket(pcm)
        #expect(packet.prefix(2) == Data([DisplayWire.micAudio, 0]) && packet.count == 6 + 1920 && packet.suffix(1920) == pcm)
        #expect(DisplayWire.micUnavailablePacket() == Data([DisplayWire.micUnavailable, 0, 0, 0, 0, 0]))
    }
}
