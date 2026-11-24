import Foundation
import NativeAdb

/// A phone call's sound on this Mac: their voice plays here, and this Mac's microphone goes into
/// the call (the phone's own microphone is off meanwhile). One "call" stream on the display socket,
/// with the same single-use ticket and proofs as a window's streams. Closing it gives the call
/// back to the phone.
public final class CallAudioSession: @unchecked Sendable {
    private let token: String
    private let requestTicket: @Sendable () async -> Data?
    private let id: Data
    private let player = Platforms.current.makeAudioOutput()
    private let mic = Platforms.current.makeMicrophone()
    private let sending = DispatchQueue(label: "nearside.call-mic")
    private let lock = NSLock()
    private var stream: AdbStream?
    private var closed = false
    private var reported = false
    /// On the main actor: the phone took the call back (it ended, or this couldn't start).
    public var onEnded: (@Sendable () -> Void)?

    public init(token: String, requestTicket: @escaping @Sendable () async -> Data?) {
        self.token = token
        self.requestTicket = requestTicket
        id = secureRandomBytes(16)
    }

    public func start() {
        Task.detached { [self] in
            guard let ticket = await requestTicket(), let adb = Native.current(),
                  let stream = try? adb.open("localabstract:nearside-display", window: 256 * 1024),
                  (try? stream.write(DisplayWire.hello(role: .call, session: id, ticket: ticket, token: token))) != nil else {
                NSLog("Nearside: call audio: couldn't reach the phone")
                return ended()
            }
            let late = lock.withLock { () -> Bool in
                if closed { return true }
                self.stream = stream
                return false
            }
            if late { return stream.close() }
            run(stream, ticket: ticket)
        }
    }

    /// Gives the call back to the phone.
    public func stop() {
        let stream = lock.withLock { () -> AdbStream? in
            closed = true
            return self.stream
        }
        stream?.close()
        mic.want(false) // and a start still waiting on the permission prompt won't happen
        player.stop()
    }

    private func run(_ stream: AdbStream, ticket: Data) {
        mic.onChunk = { [sending, mic] chunk in
            sending.async {
                guard PhoneSound.microphone else {
                    mic.want(false)
                    try? stream.write(DisplayWire.micUnavailablePacket(), timeout: 1)
                    return
                }
                try? stream.write(DisplayWire.micAudioPacket(chunk), timeout: 1)
            }
        }
        defer {
            mic.want(false)
            player.stop()
            stream.close()
            ended()
        }
        var reader = DisplayWire.Reader()
        let expected = DisplayWire.serverProof(role: .call, session: id, ticket: ticket, token: token)
        var proven = false
        while let data = try? stream.read() {
            var messages = reader.feed(data)
            if reader.failed { return }
            if !proven {
                // Nothing is sent or played until the other end proves it's our helper.
                guard let first = messages.first else { continue }
                guard case .serverHello(let proof) = first, proof == expected else { return }
                proven = true
                messages.removeFirst()
                NSLog("Nearside: call audio: connected")
            }
            for message in messages {
                switch message {
                case let .audioConfig(rate, channels):
                    player.configure(sampleRate: rate, channels: channels)
                case let .audio(pts, data):
                    if data.isEmpty { player.silence() } else { player.play(data, ptsMicros: pts, receivedMicros: monotonicMicros()) }
                case let .mic(on):
                    if lock.withLock({ closed }) { break }
                    mic.want(on)
                    guard on else { break }
                    Task.detached { [mic, sending] in
                        if await Platforms.current.microphoneAllowed(), PhoneSound.microphone, mic.start() { return }
                        NSLog("Nearside: call audio: no microphone on this Mac; the call goes back to the phone")
                        sending.async { try? stream.write(DisplayWire.micUnavailablePacket(), timeout: 1) }
                    }
                default:
                    break
                }
            }
        }
    }

    private func ended() {
        let first = lock.withLock { () -> Bool in
            defer { reported = true; closed = true }
            return !reported
        }
        guard first, let onEnded else { return }
        DispatchQueue.main.async { onEnded() }
    }
}
