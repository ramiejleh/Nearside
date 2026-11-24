import Foundation
import NearsideCore

// A phone window's sound: Opus packets from the phone, decoded by the app (FFmpeg), held in the
// engine's jitter buffer (the Mac's, from core), and pulled by the app's output (WASAPI) as it
// plays. Video is never held back for it.

/// (session, kind, data, length, sample rate, channels, out, out capacity in samples) → samples
/// decoded into `out` for kind 1. Kinds: 0 configure, 1 decode `data`, 2 silence, 3 stop.
public typealias NearsideAudioCallback = @convention(c) (Int64, Int32, UnsafePointer<UInt8>?, Int32, Int32, Int32,
                                                         UnsafeMutablePointer<Float>?, Int32) -> Int32

enum AudioMedia {
    static let lock = NSLock()
    nonisolated(unsafe) static var callback: NearsideAudioCallback?
    nonisolated(unsafe) static var outputs: [Int64: BridgeAudio] = [:]

    static func output(_ session: Int64) -> BridgeAudio? { lock.withLock { outputs[session] } }
}

final class BridgeAudio: AudioOutput, @unchecked Sendable {
    let session: Int64
    /// Guards the buffer and counters; the app's output thread takes it to read, briefly.
    private let lock = NSLock()
    private var buffer: JitterBuffer?
    private var sampleRate = 0, channels = 0
    private var packets = 0
    private var scratch = [Float](repeating: 0, count: 48_000 / 10 * 2) // 120 ms of stereo at most

    init(session: Int64) { self.session = session }

    func configure(sampleRate: Int, channels: Int) {
        let same = lock.withLock { self.sampleRate == sampleRate && self.channels == channels && buffer != nil }
        if same { return }
        lock.withLock {
            self.sampleRate = sampleRate
            self.channels = channels
            buffer = JitterBuffer(channels: channels, sampleRate: sampleRate)
            scratch = [Float](repeating: 0, count: sampleRate / 10 * channels)
        }
        _ = call(0, Data(), sampleRate: sampleRate, channels: channels, out: nil, capacity: 0)
    }

    /// Called from the session's audio reading thread only (so `scratch` is its own).
    func play(_ packet: Data, ptsMicros: Int64, receivedMicros: Int64) {
        let (rate, count) = lock.withLock { (sampleRate, channels) }
        guard rate > 0 else { return }
        let decoded = scratch.withUnsafeMutableBufferPointer { out in
            Int(call(1, packet, sampleRate: rate, channels: count, out: out.baseAddress, capacity: Int32(out.count)))
        }
        guard decoded > 0 else { return }
        let samples = Array(scratch[0..<min(decoded, scratch.count)])
        lock.withLock {
            buffer?.write(samples)
            packets += 1
        }
    }

    func silence() {
        lock.withLock { buffer?.endOfSound() }
        _ = call(2, Data(), sampleRate: 0, channels: 0, out: nil, capacity: 0)
    }

    var stats: (packets: Int, underruns: Int, dropped: Int, buffered: Int) {
        lock.withLock { (packets, buffer?.underruns ?? 0, buffer?.dropped ?? 0, buffer?.buffered ?? 0) }
    }

    func stop() {
        lock.withLock { buffer = nil; sampleRate = 0; channels = 0 }
        _ = call(3, Data(), sampleRate: 0, channels: 0, out: nil, capacity: 0)
        AudioMedia.lock.withLock { AudioMedia.outputs[session] = nil }
    }

    /// The app's output, for `frames` frames: audio while playing, silence while filling up.
    func read(into out: UnsafeMutablePointer<Float>, frames: Int, channels wanted: Int) {
        lock.withLock {
            guard buffer != nil, wanted == channels else {
                out.update(repeating: 0, count: frames * wanted)
                return
            }
            buffer!.read(into: out, frames: frames)
        }
    }

    private func call(_ kind: Int32, _ data: Data, sampleRate: Int, channels: Int, out: UnsafeMutablePointer<Float>?, capacity: Int32) -> Int32 {
        guard let callback = AudioMedia.lock.withLock({ AudioMedia.callback }) else { return 0 }
        return data.withUnsafeBytes { raw in
            callback(session, kind, raw.bindMemory(to: UInt8.self).baseAddress, Int32(raw.count), Int32(sampleRate), Int32(channels), out, capacity)
        }
    }
}

@_cdecl("nearside_set_audio")
public func nearside_set_audio(_ callback: NearsideAudioCallback) {
    AudioMedia.lock.withLock { AudioMedia.callback = callback }
}

/// The app's output thread: the next `frames` frames of a session's sound (interleaved).
@_cdecl("nearside_audio_read")
public func nearside_audio_read(_ session: Int64, _ out: UnsafeMutablePointer<Float>, _ frames: Int32, _ channels: Int32) {
    guard let output = AudioMedia.output(session) else {
        out.update(repeating: 0, count: Int(frames * channels))
        return
    }
    output.read(into: out, frames: Int(frames), channels: Int(channels))
}
