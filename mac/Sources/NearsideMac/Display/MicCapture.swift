import AVFoundation
import Foundation
import NearsideCore

/// This Mac's microphone for an app in a phone window (a call, a voice note): on only while the
/// app records, as 20 ms chunks of 48 kHz mono 16-bit PCM.
public final class MicCapture: Microphone, @unchecked Sendable {
    /// 20 ms of samples, on the audio thread. Set before start().
    public var onChunk: (Data) -> Void
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var running = false
    /// The phone's app records (start() does nothing otherwise: a stop may beat a permission prompt).
    private var wanted = false
    private var pending = Data()
    private static let chunkBytes = DisplayWire.micSampleRate / 50 * 2
    private static let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(DisplayWire.micSampleRate),
                                              channels: 1, interleaved: true)!

    public init(onChunk: @escaping (Data) -> Void = { _ in }) {
        self.onChunk = onChunk
    }

    /// Whether this Mac may use its microphone, asking the first time.
    public static func allowed() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    /// The phone's app started (or stopped) recording.
    public func want(_ on: Bool) {
        lock.withLock { wanted = on }
        if !on { stop() }
    }

    /// False if the microphone can't be opened.
    @discardableResult
    public func start() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard wanted, !running else { return true }
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, let converter = AVAudioConverter(from: inputFormat, to: Self.format) else { return false }
        pending = Data()
        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            self?.convert(buffer, with: converter)
        }
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            NSLog("Nearside: microphone didn't start: \(error)")
            return false
        }
        running = true
        return true
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard running else { return }
        running = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    private func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter) {
        let ratio = Self.format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: capacity) else { return }
        var given = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if given { status.pointee = .noDataNow; return nil }
            given = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, out.frameLength > 0, let samples = out.int16ChannelData else { return }
        pending.append(Data(bytes: samples[0], count: Int(out.frameLength) * 2))
        while pending.count >= Self.chunkBytes {
            onChunk(MicrophoneMute.muted ? Data(count: Self.chunkBytes) : Data(pending.prefix(Self.chunkBytes)))
            pending.removeFirst(Self.chunkBytes)
        }
    }
}
