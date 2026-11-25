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
    /// Held across configuring and decoding, so the scratch buffer is never swapped under a decode
    /// (an old reader may still run after a reconnect). Never taken by the output thread.
    private let decoding = NSLock()
    private var scratch = [Float](repeating: 0, count: 48_000 / 10 * 2) // 100 ms of stereo

    init(session: Int64) { self.session = session }

    func configure(sampleRate: Int, channels: Int) {
        decoding.withLock {
            let same = lock.withLock { self.sampleRate == sampleRate && self.channels == channels && buffer != nil }
            if same { return }
            lock.withLock {
                self.sampleRate = sampleRate
                self.channels = channels
                buffer = JitterBuffer(channels: channels, sampleRate: sampleRate)
            }
            scratch = [Float](repeating: 0, count: max(sampleRate, 1) / 10 * max(channels, 1))
            _ = call(0, Data(), sampleRate: sampleRate, channels: channels, out: nil, capacity: 0)
        }
    }

    func play(_ packet: Data, ptsMicros: Int64, receivedMicros: Int64) {
        let samples: [Float]? = decoding.withLock {
            let (rate, count) = lock.withLock { (sampleRate, channels) }
            guard rate > 0 else { return nil }
            let decoded = scratch.withUnsafeMutableBufferPointer { out in
                Int(call(1, packet, sampleRate: rate, channels: count, out: out.baseAddress, capacity: Int32(out.count)))
            }
            guard decoded > 0 else { return nil }
            return Array(scratch[0..<min(decoded, scratch.count)])
        }
        guard let samples else { return }
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
        decoding.withLock {
            lock.withLock { buffer = nil; sampleRate = 0; channels = 0 }
            _ = call(3, Data(), sampleRate: 0, channels: 0, out: nil, capacity: 0)
        }
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

// This PC's microphone, for an app in a phone window (a call, a voice note) and for phone calls
// talked here: the app captures it (WASAPI) as 20 ms chunks of 48 kHz mono 16-bit PCM.

/// (session, kind) → 1 if it worked. Kinds: 0 start, 1 stop.
public typealias NearsideMicCallback = @convention(c) (Int64, Int32) -> Int32

enum MicMedia {
    static let lock = NSLock()
    nonisolated(unsafe) static var callback: NearsideMicCallback?
    nonisolated(unsafe) static var mics: [Int64: BridgeMicrophone] = [:]
    nonisolated(unsafe) private static var last: Int64 = 0

    /// Microphones are made on any thread (a window's, once its app records), so each has its own id.
    static func nextID() -> Int64 { lock.withLock { last += 1; return last } }
}

final class BridgeMicrophone: Microphone, @unchecked Sendable {
    let session = MicMedia.nextID()
    private let lock = NSLock()
    /// Held across starting and stopping (the app's capture included), so a stop can't slip in
    /// while a start is underway and leave it recording.
    private let control = NSLock()
    private var wanted = false, running = false
    private var chunk: (Data) -> Void = { _ in }

    var onChunk: (Data) -> Void {
        get { lock.withLock { chunk } }
        set { lock.withLock { chunk = newValue } }
    }

    func want(_ on: Bool) {
        lock.withLock { wanted = on }
        if !on { stop() } // waits for a start underway, then stops it
    }

    /// False if the microphone can't be opened (none, or Windows' privacy settings say no).
    @discardableResult func start() -> Bool {
        control.withLock {
            let go = lock.withLock { wanted && !running }
            guard go else { return true }
            MicMedia.lock.withLock { MicMedia.mics[session] = self }
            guard let callback = MicMedia.lock.withLock({ MicMedia.callback }), callback(session, 0) == 1 else {
                MicMedia.lock.withLock { MicMedia.mics[session] = nil }
                return false
            }
            lock.withLock { running = true }
            return true
        }
    }

    func stop() {
        control.withLock {
            let was = lock.withLock { () -> Bool in
                defer { running = false }
                return running
            }
            guard was else { return }
            _ = MicMedia.lock.withLock({ MicMedia.callback })?(session, 1)
            MicMedia.lock.withLock { if MicMedia.mics[session] === self { MicMedia.mics[session] = nil } }
        }
    }

    /// From the app's capture thread; muted (the in-call card) sends silence instead.
    func deliver(_ samples: UnsafePointer<Int16>, count: Int) {
        let chunk = lock.withLock { running ? self.chunk : nil }
        guard let chunk else { return }
        if MicrophoneMute.muted {
            chunk(Data(count: count * 2))
        } else {
            chunk(Data(bytes: samples, count: count * 2))
        }
    }
}

@_cdecl("nearside_set_mic")
public func nearside_set_mic(_ callback: NearsideMicCallback) {
    MicMedia.lock.withLock { MicMedia.callback = callback }
}

/// 20 ms of 48 kHz mono 16-bit samples from this PC's microphone (the app's capture thread).
@_cdecl("nearside_mic_chunk")
public func nearside_mic_chunk(_ session: Int64, _ samples: UnsafePointer<Int16>, _ count: Int32) {
    guard count > 0, let mic = MicMedia.lock.withLock({ MicMedia.mics[session] }) else { return }
    mic.deliver(samples, count: Int(count))
}
