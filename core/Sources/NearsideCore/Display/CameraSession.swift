import Foundation
import NativeAdb

private let log = Log("webcam")

/// The phone's camera on this Mac: one "camera" stream on the display socket (same single-use
/// ticket and proofs as a window's streams). The phone's camera is on exactly while this runs.
public final class CameraSession: @unchecked Sendable {
    public let front: Bool
    private let width: Int, height: Int, fps: Int
    private let token: String
    private let requestTicket: @Sendable () async -> Data?
    private let id: Data
    private let decoder = Platforms.current.makeVideoDecoder(codec: Platforms.current.preferredCodec)
    private let lock = NSLock()
    private var stream: AdbStream?
    private var closed = false
    /// Decoded pictures, on the decoder's thread.
    public var onFrame: (@Sendable (any VideoFrame) -> Void)?
    /// Degrees clockwise to turn the picture upright (the sensor's mounting).
    public var onRotation: (@Sendable (Int) -> Void)?
    /// The stream ended (the phone went, or the camera couldn't open).
    public var onEnded: (@Sendable () -> Void)?

    public init(front: Bool, width: Int = 1920, height: Int = 1080, fps: Int = 30,
                token: String, requestTicket: @escaping @Sendable () async -> Data?) {
        self.front = front
        self.width = width; self.height = height; self.fps = fps
        self.token = token
        self.requestTicket = requestTicket
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        id = Data(bytes)
    }

    public func start() {
        decoder.onFrame = { [weak self] in self?.onFrame?($0) }
        Task.detached { [self] in
            guard let ticket = await requestTicket() else { log.error("camera: no ticket from the phone"); onEnded?(); return }
            guard let adb = Native.current(),
                  let stream = try? adb.open("localabstract:nearside-display", window: 2 * 1024 * 1024),
                  (try? stream.write(DisplayWire.hello(role: .camera, session: id, ticket: ticket, token: token))) != nil else {
                log.error("camera: couldn't open the stream to the phone")
                onEnded?()
                return
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

    public func stop() {
        let stream = lock.withLock { () -> AdbStream? in
            closed = true
            return self.stream
        }
        stream?.close()
        decoder.invalidate()
    }

    private func run(_ stream: AdbStream, ticket: Data) {
        defer {
            stream.close()
            onEnded?()
        }
        var reader = DisplayWire.Reader()
        let expected = DisplayWire.serverProof(role: .camera, session: id, ticket: ticket, token: token)
        var proven = false
        while let data = try? stream.read() {
            var messages = reader.feed(data)
            if reader.failed { return }
            if !proven {
                guard let first = messages.first else { continue }
                guard case .serverHello(let proof) = first, proof == expected else { log.error("camera: the phone's proof didn't match"); return }
                proven = true
                messages.removeFirst()
                log.notice("camera: connected to the phone")
                // Only now, to the proven helper: which camera.
                guard (try? stream.write(DisplayWire.cameraOpen(front: front, width: width, height: height, fps: fps, codec: decoder.codec))) != nil else { return }
                // Every 5 s: the phone turns its camera off after 15 s without hearing from us.
                Thread { [weak self] in
                    while let self, !self.lock.withLock({ self.closed }) {
                        guard (try? stream.write(DisplayWire.packet(DisplayWire.ping, Data(count: 8)), timeout: 2)) != nil else { break }
                        Thread.sleep(forTimeInterval: 5)
                    }
                }.start()
            }
            for message in messages {
                switch message {
                case let .cameraInfo(rotation, _):
                    onRotation?(rotation)
                case let .config(gen, _, _, sets):
                    _ = decoder.configure(parameterSets: sets, gen: gen)
                case let .frame(gen, pts, _, _, data):
                    decoder.decode(annexB: data, gen: gen, ptsMicros: pts, receivedMicros: monotonicMicros())
                default:
                    break
                }
            }
        }
    }
}
