import AudioToolbox
import AVFoundation
import Foundation

/// Opus packets → interleaved Float32 PCM, with the Mac's own decoder (AudioToolbox).
public final class OpusDecoder {
    public let sampleRate: Int
    public let channels: Int
    private var converter: AudioConverterRef?
    /// The packet `decode` is working on, for the converter's input callback.
    fileprivate var pending: Data?
    /// Its bytes and description as the converter reads them (they must outlive the callback).
    fileprivate var bytes = UnsafeMutableRawPointer.allocate(byteCount: 4096, alignment: 16)
    fileprivate var capacity = 4096
    fileprivate let description = UnsafeMutablePointer<AudioStreamPacketDescription>.allocate(capacity: 1)

    public init?(sampleRate: Int, channels: Int) {
        self.sampleRate = sampleRate
        self.channels = channels
        var input = AudioStreamBasicDescription(mSampleRate: Float64(sampleRate), mFormatID: kAudioFormatOpus, mFormatFlags: 0,
                                                mBytesPerPacket: 0, mFramesPerPacket: UInt32(sampleRate / 50), mBytesPerFrame: 0,
                                                mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 0, mReserved: 0)
        var output = Self.pcmFormat(sampleRate: sampleRate, channels: channels)
        guard AudioConverterNew(&input, &output, &converter) == noErr else { return nil }
    }

    deinit {
        if let converter { AudioConverterDispose(converter) }
        bytes.deallocate()
        description.deallocate()
    }

    static func pcmFormat(sampleRate: Int, channels: Int) -> AudioStreamBasicDescription {
        let bytes = UInt32(4 * channels)
        return AudioStreamBasicDescription(mSampleRate: Float64(sampleRate), mFormatID: kAudioFormatLinearPCM,
                                           mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                           mBytesPerPacket: bytes, mFramesPerPacket: 1, mBytesPerFrame: bytes,
                                           mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 32, mReserved: 0)
    }

    /// The packet's samples (interleaved), or nil if it didn't decode.
    public func decode(_ packet: Data) -> [Float]? {
        guard let converter, !packet.isEmpty else { return nil }
        pending = packet
        let maxFrames = sampleRate / 10 // Opus packets are at most 120 ms
        var out = [Float](repeating: 0, count: maxFrames * channels)
        var frames = UInt32(maxFrames)
        let status = out.withUnsafeMutableBytes { raw -> OSStatus in
            var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: UInt32(channels),
                                                                               mDataByteSize: UInt32(raw.count), mData: raw.baseAddress))
            return AudioConverterFillComplexBuffer(converter, opusInput, Unmanaged.passUnretained(self).toOpaque(), &frames, &list, nil)
        }
        pending = nil
        // "No more input" (our callback's code) after a full packet is fine.
        guard status == noErr || status == OpusDecoder.noMoreInput, frames > 0 else { return nil }
        return Array(out.prefix(Int(frames) * channels))
    }

    static let noMoreInput: OSStatus = 0x6E6F_6D6F // "nomo"
}

private func opusInput(_ converter: AudioConverterRef, _ packets: UnsafeMutablePointer<UInt32>, _ data: UnsafeMutablePointer<AudioBufferList>,
                       _ descriptions: UnsafeMutablePointer<UnsafeMutablePointer<AudioStreamPacketDescription>?>?,
                       _ user: UnsafeMutableRawPointer?) -> OSStatus {
    let decoder = Unmanaged<OpusDecoder>.fromOpaque(user!).takeUnretainedValue()
    guard let packet = decoder.pending else {
        packets.pointee = 0
        return OpusDecoder.noMoreInput
    }
    if packet.count > decoder.capacity {
        decoder.bytes.deallocate()
        decoder.bytes = UnsafeMutableRawPointer.allocate(byteCount: packet.count, alignment: 16)
        decoder.capacity = packet.count
    }
    packet.copyBytes(to: decoder.bytes.assumingMemoryBound(to: UInt8.self), count: packet.count)
    decoder.pending = nil
    data.pointee.mNumberBuffers = 1
    data.pointee.mBuffers.mData = decoder.bytes
    data.pointee.mBuffers.mDataByteSize = UInt32(packet.count)
    data.pointee.mBuffers.mNumberChannels = UInt32(decoder.channels)
    decoder.description.pointee = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(packet.count))
    descriptions?.pointee = decoder.description
    packets.pointee = 1
    return noErr
}

/// The audio waiting to be played: a ring of interleaved samples between the network and the
/// output. It starts (and restarts after running dry) once `target` frames are in, and drops the
/// oldest when more than `target + slack` pile up, so delay stays near `target`. The target adapts
/// to the network: it starts at `minTarget` (40 ms), grows by `step` after each underrun (Wi-Fi
/// delivers in bursts: gaps of 80–96 ms about once a second were measured), up to `maxTarget`,
/// and shrinks by `step / 2` after `calm` frames without one. A backlog left by a burst (audio
/// that sat unused for a whole `window`) is trimmed back to the target, so delay doesn't creep up.
public struct JitterBuffer {
    public let channels: Int
    public private(set) var target: Int
    public let minTarget: Int
    public let maxTarget: Int
    public let slack: Int
    public let step: Int
    public let calm: Int
    public let window: Int
    public var limit: Int { target + slack }
    private var samples: [Float]
    private var read = 0
    private var count = 0
    private var playedSinceUnderrun = 0
    private var playedInWindow = 0
    private var lowWater = Int.max
    public private(set) var playing = false
    public private(set) var underruns = 0
    public private(set) var dropped = 0

    /// All in frames.
    public init(channels: Int, minTarget: Int, maxTarget: Int, slack: Int, step: Int, calm: Int, window: Int) {
        self.channels = channels
        self.target = minTarget
        self.minTarget = minTarget
        self.maxTarget = maxTarget
        self.slack = slack
        self.step = step
        self.calm = calm
        self.window = window
        samples = [Float](repeating: 0, count: (maxTarget + slack) * channels * 2)
    }

    /// For a sample rate: 40…200 ms, 100 ms of slack, steps of 20 ms, calm after 30 s (shrinking
    /// sooner just brought the next underrun: this Wi-Fi had ~80 ms gaps every few seconds), 2 s windows.
    public init(channels: Int, sampleRate: Int) {
        let ms = sampleRate / 1000
        self.init(channels: channels, minTarget: 40 * ms, maxTarget: 200 * ms, slack: 100 * ms, step: 20 * ms,
                  calm: 30 * sampleRate, window: 2 * sampleRate)
    }

    public var buffered: Int { count / channels }

    public mutating func write(_ new: [Float]) {
        for sample in new {
            if count == samples.count { read = (read + 1) % samples.count; count -= 1 }
            samples[(read + count) % samples.count] = sample
            count += 1
        }
        if buffered > limit {
            let drop = (buffered - target) * channels
            read = (read + drop) % samples.count
            count -= drop
            dropped += drop / channels
        }
        if !playing, buffered >= target { playing = true }
    }

    /// Fills `out` (interleaved, `frames` frames): with audio while playing, silence while
    /// waiting to fill up again.
    public mutating func read(into out: UnsafeMutablePointer<Float>, frames: Int) {
        let wanted = frames * channels
        guard playing else {
            out.update(repeating: 0, count: wanted)
            return
        }
        let n = min(wanted, count)
        for i in 0..<n { out[i] = samples[(read + i) % samples.count] }
        read = (read + n) % samples.count
        count -= n
        if n < wanted {
            (out + n).update(repeating: 0, count: wanted - n)
            playing = false
            underruns += 1
            target = min(target + step, maxTarget)
            playedSinceUnderrun = 0
            playedInWindow = 0
            lowWater = .max
        } else {
            playedSinceUnderrun += frames
            if playedSinceUnderrun >= calm {
                target = max(target - step / 2, minTarget)
                playedSinceUnderrun = 0
            }
            lowWater = min(lowWater, buffered)
            playedInWindow += frames
            if playedInWindow >= window {
                // Never dipped below lowWater all window: the part above the target is only delay.
                if lowWater > target + step / 2 {
                    let drop = (lowWater - target) * channels
                    read = (read + drop) % samples.count
                    count -= drop
                    dropped += drop / channels
                }
                playedInWindow = 0
                lowWater = .max
            }
        }
    }
}

/// A window's sound on the Mac: Opus from the phone, decoded and played through the default
/// output with a small jitter buffer. Video is never held back for it.
public final class AudioPlayer: @unchecked Sendable {
    private let lock = NSLock()
    private var decoder: OpusDecoder?
    private var buffer: JitterBuffer?
    private var engine: AVAudioEngine?
    private var node: AVAudioSourceNode?
    private var configObserver: NSObjectProtocol?
    private var scratch: UnsafeMutablePointer<Float>?
    private var packets = 0
    private var peak: Float = 0

    public init() {}

    public func configure(sampleRate: Int, channels: Int) {
        let same = lock.withLock { decoder?.sampleRate == sampleRate && decoder?.channels == channels }
        if same { return }
        stop()
        guard let decoder = OpusDecoder(sampleRate: sampleRate, channels: channels) else {
            NSLog("Nearside: no Opus decoder for \(sampleRate) Hz × \(channels)")
            return
        }
        lock.withLock {
            self.decoder = decoder
            buffer = JitterBuffer(channels: channels, sampleRate: sampleRate)
        }
        start(sampleRate: sampleRate, channels: channels)
    }

    /// Arrival gaps over 60 ms and the largest, since the last report (the network's jitter).
    private var lateArrivals = 0
    private var maxGap: Int64 = 0
    private var lastArrival: Int64 = 0
    private var lastPts: Int64 = 0

    public func play(_ packet: Data, ptsMicros: Int64 = 0, receivedMicros: Int64 = 0) {
        lock.withLock {
            if lastArrival > 0 {
                let gap = receivedMicros - lastArrival
                maxGap = max(maxGap, gap)
                if gap > 60_000 { lateArrivals += 1 }
                if ptsMicros - lastPts > 30_000 { Trace.log("audio pts gap \((ptsMicros - lastPts) / 1000) ms") }
            }
            lastArrival = receivedMicros
            lastPts = ptsMicros
        }
        guard let samples = lock.withLock({ decoder?.decode(packet) }) else { return }
        let loudest = samples.reduce(Float(0)) { max($0, abs($1)) }
        let report = lock.withLock { () -> String? in
            buffer?.write(samples)
            packets += 1
            peak = max(peak, loudest)
            guard packets % 250 == 0, let b = buffer else { return nil } // every 5 s
            defer { peak = 0; lateArrivals = 0; maxGap = 0 }
            return "\(packets) packets, gaps >60 ms \(lateArrivals) (max \(maxGap / 1000) ms), peak \(String(format: "%.2f", peak)), buffered \(b.buffered * 1000 / max(decoder?.sampleRate ?? 1, 1)) ms (target \(b.target * 1000 / max(decoder?.sampleRate ?? 1, 1))), underruns \(b.underruns), dropped \(b.dropped) frames"
        }
        if let report { Trace.log("audio \(report)") }
    }

    private func start(sampleRate: Int, channels: Int) {
        // The engine's own format: one buffer per channel (it refuses interleaved here).
        guard let format = AVAudioFormat(standardFormatWithSampleRate: Double(sampleRate),
                                         channels: AVAudioChannelCount(channels)) else { return }
        let scratch = UnsafeMutablePointer<Float>.allocate(capacity: 8192 * channels) // interleaved, reused
        let node = AVAudioSourceNode(format: format) { [weak self] _, _, frameCount, list -> OSStatus in
            guard let self else { return noErr }
            let frames = min(Int(frameCount), 8192)
            lock.withLock {
                if self.buffer != nil { self.buffer!.read(into: scratch, frames: frames) }
                else { scratch.update(repeating: 0, count: frames * channels) }
            }
            for (c, buffer) in UnsafeMutableAudioBufferListPointer(list).enumerated() where c < channels {
                guard let out = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                for i in 0..<frames { out[i] = scratch[i * channels + c] }
            }
            return noErr
        }
        self.scratch = scratch
        let engine = AVAudioEngine()
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        do {
            try engine.start()
        } catch {
            NSLog("Nearside: audio output failed: \(error)")
            return
        }
        // Headphones plugged in, output switched: the engine stops; start it on the new device.
        configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine,
                                                                queue: nil) { [weak engine] _ in
            try? engine?.start()
        }
        lock.withLock {
            self.engine = engine
            self.node = node
        }
    }

    /// For the stats log: (packets, underruns, dropped frames, buffered frames).
    public var stats: (packets: Int, underruns: Int, dropped: Int, buffered: Int) {
        lock.withLock { (packets, buffer?.underruns ?? 0, buffer?.dropped ?? 0, buffer?.buffered ?? 0) }
    }

    public func stop() {
        let (engine, observer) = lock.withLock { () -> (AVAudioEngine?, NSObjectProtocol?) in
            defer { self.engine = nil; node = nil; decoder = nil; buffer = nil; configObserver = nil }
            return (self.engine, configObserver)
        }
        if let observer { NotificationCenter.default.removeObserver(observer) }
        engine?.stop()
        // The render block owns `scratch` until the engine has stopped.
        lock.withLock {
            scratch?.deallocate()
            scratch = nil
        }
    }
}
