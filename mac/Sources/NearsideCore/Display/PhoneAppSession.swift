import CoreGraphics
import CoreVideo
import Foundation
import NativeAdb

/// One phone app in one Mac window: two adb streams to the helper's display server (control and
/// video), hardware decoding, input going back. Survives short drops (Wi-Fi blip, Mac sleep): it
/// resumes the same phone-side session, so the app is never relaunched.
public final class PhoneAppSession: @unchecked Sendable {
    public enum State: Equatable, Sendable {
        case opening
        case showing
        case reconnecting
        /// The app left the window: closed on the phone, or opened there.
        case gone(DisplayWire.GoneReason)
        case failed(String)
        /// The phone couldn't make another video encoder: too many windows.
        case busy
        case closed
    }

    public let target: String
    /// Decoded frames, on VideoToolbox's thread.
    public var onFrame: (@Sendable (VideoDecoder.Frame) -> Void)?
    /// State changes, on the main thread.
    public var onState: (@MainActor @Sendable (State) -> Void)?
    /// The phone is warm and the quality reduced (true), or back to normal, on the main thread.
    public var onThermal: (@MainActor @Sendable (Bool) -> Void)?
    /// An app window blocks capture (FLAG_SECURE), or stopped blocking, on the main thread.
    public var onSecure: (@MainActor @Sendable (Bool) -> Void)?
    /// The video's pixel size (it changes after a resize), on the main thread.
    public var onVideoSize: (@MainActor @Sendable (CGSize) -> Void)?

    private let requestTicket: @Sendable () async -> Data?
    private let token: String
    private let id: Data
    private let lock = NSLock()
    private var control: AdbStream?
    private var video: AdbStream?
    private var audio: AdbStream?
    private let player = AudioPlayer()
    private var state: State = .opening
    private var gen: UInt32 = 0
    private var closing = false
    private var size: (width: Int, height: Int, dpi: Int)
    /// Top rows of the display the window doesn't show (see PhoneDisplaySize); input maps past them.
    private var cropPixels = 0
    private let fps: Int
    private let kbps: Int
    private let writer = DispatchQueue(label: "phone-app-control")
    private let decoder = VideoDecoder()
    /// phone µs − Mac µs, from the lowest-RTT ping so far (for latency stats).
    private var clockOffset: Int64?
    private var bestRTT = Int64.max
    private var pinger: Timer?

    static let socket = "localabstract:nearside-display"
    static let graceSeconds: TimeInterval = 30

    init(target: String, width: Int, height: Int, dpi: Int, cropPixels: Int = 0, fps: Int = 60, kbps: Int = 12_000,
         token: String, requestTicket: @escaping @Sendable () async -> Data?) {
        self.target = target
        self.size = (width & ~1, height & ~1, dpi)
        self.cropPixels = cropPixels
        self.fps = fps
        self.kbps = kbps
        self.token = token
        self.requestTicket = requestTicket
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        id = Data(bytes)
    }

    public func start() {
        decoder.onFrame = { [weak self] frame in
            guard let self else { return }
            Trace.log("decoded \(frame.ptsMicros)")
            // Only opening/reconnecting become "showing": a last frame after the app closed (its
            // exit animation) must not hide the "was closed" state again.
            let current = lock.withLock { state }
            if current == .opening || current == .reconnecting { set(.showing) }
            watchForBlack(frame)
            onFrame?(frame)
        }
        Thread { [self] in
            if !connect(resume: false) { fail("Couldn't reach your phone.") }
        }.start()
    }

    // MARK: - Connecting

    /// Opens both streams; `resume` re-attaches to the phone-side session instead of opening the app.
    private func connect(resume: Bool) -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        let box = TicketBox()
        Task.detached { [requestTicket] in
            box.value = await requestTicket()
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + 5) == .success, let ticket = box.value,
              let adb = Native.current() else { return false }
        do {
            let ctl = try adb.open(Self.socket, window: 256 * 1024)
            try ctl.write(DisplayWire.hello(role: .control, session: id, ticket: ticket, token: token))
            // Nothing goes out (no app name, no input) and nothing is shown until the other end
            // proves it's our helper, not something squatting the socket name.
            guard let ctlStart = awaitServer(ctl, role: .control, ticket: ticket) else { ctl.close(); return false }
            if resume {
                try ctl.write(DisplayWire.packet(DisplayWire.resume))
            } else {
                let s = lock.withLock { size }
                try ctl.write(DisplayWire.open(width: s.width, height: s.height, dpi: s.dpi, fps: fps, kbps: kbps, target: target))
            }
            let vid = try adb.open(Self.socket, window: 2 * 1024 * 1024)
            try vid.write(DisplayWire.hello(role: .video, session: id, ticket: ticket, token: token))
            guard let vidStart = awaitServer(vid, role: .video, ticket: ticket) else {
                ctl.close(); vid.close(); return false
            }
            let stale = lock.withLock { () -> Bool in
                if closing { return true }
                control = ctl
                video = vid
                return false
            }
            if stale { ctl.close(); vid.close(); return true }
            if let hint = lock.withLock({ layoutHint }) { try ctl.write(DisplayWire.utf8(DisplayWire.layout, hint)) }
            DispatchQueue.main.async { [self] in startPinging() }
            Thread { [self] in readControl(ctl, ctlStart) }.start()
            Thread { [self] in readVideo(vid, vidStart) }.start()
            Thread { [self] in openAudio(adb, ticket) }.start()
            return true
        } catch {
            return false
        }
    }

    /// Reads until the helper's HELLO and checks its proof; returns the reader (it may already
    /// hold messages that followed in the same chunk) and those messages.
    private func awaitServer(_ stream: AdbStream, role: DisplayWire.Role, ticket: Data) -> (DisplayWire.Reader, [DisplayWire.Message])? {
        var reader = DisplayWire.Reader()
        let expected = DisplayWire.serverProof(role: role, session: id, ticket: ticket, token: token)
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            guard let data = try? stream.read(timeout: deadline.timeIntervalSinceNow) else { return nil }
            var messages = reader.feed(data)
            guard !reader.failed else { return nil }
            guard let first = messages.first else { continue }
            guard case .serverHello(let proof) = first, proof == expected else { return nil }
            messages.removeFirst()
            return (reader, messages)
        }
        return nil
    }

    private func readControl(_ stream: AdbStream, _ start: (DisplayWire.Reader, [DisplayWire.Message])) {
        var (reader, pending) = start
        func handle(_ message: DisplayWire.Message) {
            switch message {
            case .taskGone(let reason): set(.gone(reason))
            case .error(4, _): set(.busy)
            case .error(_, let text): fail(text.isEmpty ? "The app couldn't be opened." : text)
            case .secure(let on):
                if let onSecure { Task { @MainActor in onSecure(on) } }
            case .thermal(let reduced):
                if let onThermal { Task { @MainActor in onThermal(reduced) } }
            case let .pong(t0, phone):
                let now = monotonicMicros(), rtt = now - Int64(t0)
                lock.withLock {
                    if rtt < bestRTT { bestRTT = rtt; clockOffset = Int64(phone) - (Int64(t0) + now) / 2 }
                }
                if rtt > 50_000 { Trace.log("rtt \(rtt / 1000) ms") }
            default: break
            }
        }
        pending.forEach(handle)
        while let data = try? stream.read() {
            reader.feed(data).forEach(handle)
            if reader.failed { break }
        }
        streamEnded(stream)
    }

    private func readVideo(_ stream: AdbStream, _ start: (DisplayWire.Reader, [DisplayWire.Message])) {
        var (reader, pending) = start
        while true {
            if pending.isEmpty {
                guard let data = try? stream.read() else { break }
                Self.throttleForTesting(data.count)
                pending = reader.feed(data)
            }
            let now = monotonicMicros()
            let batch = pending
            pending = []
            for message in batch {
                switch message {
                case let .config(gen, width, height, sets):
                    NSLog("Nearside: phone app \(target): video \(width)x\(height) (gen \(gen))")
                    if decoder.configure(parameterSets: sets, gen: gen) {
                        lock.withLock { self.gen = gen }
                        let size = CGSize(width: width, height: height)
                        if let onVideoSize { Task { @MainActor in onVideoSize(size) } }
                    }
                case let .frame(gen, pts, encoded, _, data):
                    if Trace.enabled, let offset = lock.withLock({ clockOffset }) {
                        Trace.log("recv \(pts) capture→recv \((now - (pts - offset)) / 1000) ms encode \((encoded - pts) / 1000) ms size \(data.count)")
                    } else {
                        Trace.log("recv \(pts)")
                    }
                    send(DisplayWire.ack(ptsMicros: pts)) // the phone's congestion control
                    decoder.decode(annexB: data, gen: gen, ptsMicros: pts, receivedMicros: now)
                default: break
                }
            }
            if reader.failed { break }
        }
        streamEnded(stream)
    }

    /// Test hook: NEARSIDE_TEST_VIDEO_KBPS=<n> reads video no faster than that (a slow network).
    private static let testKbps = Double(ProcessInfo.processInfo.environment["NEARSIDE_TEST_VIDEO_KBPS"] ?? "")

    private static func throttleForTesting(_ bytes: Int) {
        guard let kbps = testKbps, kbps > 0 else { return }
        Thread.sleep(forTimeInterval: Double(bytes) * 8 / (kbps * 1000))
    }

    /// The sound: optional (a phone without the virtual device keeps it on its speaker and closes
    /// this stream), so it never holds up or ends the session.
    private func openAudio(_ adb: AdbConnection, _ ticket: Data) {
        guard let stream = try? adb.open(Self.socket, window: 256 * 1024) else { return NSLog("Nearside: \(target): no audio stream") }
        guard (try? stream.write(DisplayWire.hello(role: .audio, session: id, ticket: ticket, token: token))) != nil,
              let start = awaitServer(stream, role: .audio, ticket: ticket) else {
            NSLog("Nearside: \(target): audio stream refused (the phone keeps the sound)")
            return stream.close()
        }
        let (late, previous) = lock.withLock { () -> (Bool, AdbStream?) in
            if closing { return (true, nil) }
            defer { audio = stream }
            return (false, audio)
        }
        previous?.close()
        if late { stream.close(); return }
        var (reader, pending) = start
        while true {
            for message in pending {
                switch message {
                case let .audioConfig(rate, channels):
                    NSLog("Nearside: phone app \(target): sound \(rate) Hz × \(channels)")
                    player.configure(sampleRate: rate, channels: channels)
                case let .audio(pts, data):
                    player.play(data, ptsMicros: pts, receivedMicros: monotonicMicros())
                default: break
                }
            }
            guard !reader.failed, let data = try? stream.read() else { break }
            pending = reader.feed(data)
        }
    }

    /// A stream dropped without us closing it: try to resume for a while, then give up.
    private func streamEnded(_ stream: AdbStream) {
        let resume = lock.withLock { () -> Bool in
            guard control === stream || video === stream, !closing else { return false }
            control?.close(); video?.close(); audio?.close()
            control = nil; video = nil; audio = nil
            switch state {
            case .gone, .failed, .busy, .closed: return false
            default: return true
            }
        }
        guard resume else { return }
        set(.reconnecting)
        Thread { [self] in
            let deadline = Date().addingTimeInterval(Self.graceSeconds)
            while Date() < deadline, !lock.withLock({ closing }) {
                if connect(resume: true) {
                    send(DisplayWire.packet(DisplayWire.sync))
                    return
                }
                Thread.sleep(forTimeInterval: 2)
            }
            if !lock.withLock({ closing }) { fail("Lost the connection to your phone.") }
        }.start()
    }

    // MARK: - Input and window events

    private func send(_ packet: Data) {
        guard let stream = lock.withLock({ control }) else { return }
        writer.async { try? stream.write(packet) }
    }

    /// x/y normalised (0…1) within the video; `time` is the Mac event's (NSEvent.timestamp, s).
    public func touch(_ action: DisplayWire.TouchAction, pointer: UInt8 = 0, x: Float, y: Float,
                      time: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        let gen = lock.withLock { self.gen }
        let y = displayY(y)
        Trace.log("touch \(action) p\(pointer) \(x) \(y) gen \(gen)")
        send(DisplayWire.touch(action, pointer: pointer, gen: gen, x: x, y: y, micros: UInt64(max(0, time) * 1_000_000)))
    }

    public func touches(_ touches: [PointerGestures.Touch], time: TimeInterval) {
        for t in touches { touch(t.action, pointer: t.pointer, x: t.x, y: t.y, time: time) }
    }

    /// A mouse wheel at x/y (normalised); h/v in notches, + = right/up.
    public func scroll(x: Float, y: Float, h: Float, v: Float) {
        send(DisplayWire.scroll(gen: lock.withLock { gen }, x: x, y: displayY(y), h: h, v: v))
    }

    /// The mouse pointer itself: hover, and the right button.
    public func mouse(_ action: DisplayWire.MouseAction, x: Float, y: Float) {
        send(DisplayWire.mouse(action, gen: lock.withLock { gen }, x: x, y: displayY(y)))
    }

    public func back() { send(DisplayWire.packet(DisplayWire.nav, Data([1]))) }

    // MARK: Keyboard

    public func keys(_ keys: [KeyMap.Key]) { keys.forEach { send(DisplayWire.key($0)) } }

    /// Typed text (the Mac's layout already applied).
    public func text(_ text: String) { send(DisplayWire.utf8(DisplayWire.text, text)) }

    /// ⌘V: the Mac's clipboard text (nil: paste what the phone has).
    public func paste(_ text: String?) { send(DisplayWire.utf8(DisplayWire.paste, text ?? "")) }

    /// The Mac's keyboard layout ("Danish\nda"), so the phone can type every character it can.
    /// Kept, and sent again after a reconnect.
    public func setKeyboardLayout(_ hint: String) {
        lock.withLock { layoutHint = hint }
        send(DisplayWire.utf8(DisplayWire.layout, hint))
    }

    private var layoutHint: String?

    private func displayY(_ y: Float) -> Float {
        let (crop, height) = lock.withLock { (cropPixels, size.height) }
        return PhoneDisplaySize.displayY(y, cropPixels: crop, height: height)
    }

    /// The window's new pixel size; the phone re-lays the app out for it.
    public func resize(width: Int, height: Int, dpi: Int, cropPixels: Int = 0) {
        lock.withLock { size = (width & ~1, height & ~1, dpi); self.cropPixels = cropPixels }
        send(DisplayWire.resize(width: width & ~1, height: height & ~1, dpi: dpi))
    }

    /// Hidden windows stop the video (the app keeps running).
    /// How much of the phone's encoder the window gets: the window in use full rate, others on
    /// screen less, hidden ones nothing (the app keeps running).
    public enum Visibility: UInt8, Sendable { case focused = 0, hidden = 1, visible = 2 }

    public func setVisibility(_ visibility: Visibility) {
        send(DisplayWire.packet(DisplayWire.visibility, Data([visibility.rawValue])))
        DispatchQueue.main.async { [self] in
            let shown = visibility != .hidden
            guard shown != visible else { return }
            visible = shown
            startPinging()
        }
    }

    /// While the window is visible, a ping every 40 ms keeps the phone's Wi-Fi out of power save:
    /// idle, it dozes within ~100 ms and the next touch then waits for its next wake-up (measured:
    /// round trip p95 177 ms pinging once a second, 111 ms at 100 ms, 17 ms at 50 ms). Hidden, once
    /// a second is enough to keep the session alive.
    private var visible = true

    @MainActor private func startPinging() {
        pinger?.invalidate()
        guard !lock.withLock({ closing }) else { return }
        pinger = Timer.scheduledTimer(withTimeInterval: visible ? 0.04 : 1, repeats: true) { [weak self] _ in
            self?.send(DisplayWire.ping(UInt64(monotonicMicros())))
        }
        pinger?.tolerance = 0.005
    }

    // MARK: - Black pictures

    private var blackSince: Int64?
    private var reportedBlack = false
    private var frameCount = 0

    /// Samples every 10th frame; a picture all black for half a second (or no longer black) is
    /// reported, and the phone checks for an app that blocks capture.
    private func watchForBlack(_ frame: VideoDecoder.Frame) {
        frameCount += 1
        guard frameCount % 10 == 0 else { return }
        let black = Self.isBlack(frame.image)
        let now = monotonicMicros()
        if black {
            if blackSince == nil { blackSince = now }
            if !reportedBlack, now - blackSince! > 500_000 {
                reportedBlack = true
                send(DisplayWire.packet(DisplayWire.black, Data([1])))
            }
        } else {
            blackSince = nil
            if reportedBlack {
                reportedBlack = false
                send(DisplayWire.packet(DisplayWire.black, Data([0])))
            }
        }
    }

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

    /// Closes the window and brings the app to the front on the phone ("Open on Phone").
    public func openOnPhone() { close(onTop: true) }

    /// Closes the window's session; the app goes back to the phone, under what's showing there.
    public func close() { close(onTop: false) }

    private func close(onTop: Bool) {
        DispatchQueue.main.async { [self] in pinger?.invalidate() }
        let streams = lock.withLock { () -> (AdbStream?, AdbStream?)? in
            if closing { return nil } // already closed ("Open on Phone", then the window's close)
            closing = true
            state = .closed
            audio?.close()
            return (control, video)
        }
        guard let streams else { return }
        player.stop()
        writer.async {
            try? streams.0?.write(DisplayWire.packet(DisplayWire.close, Data([onTop ? 1 : 0])))
            Thread.sleep(forTimeInterval: 0.2) // let it arrive before the stream closes
            streams.0?.close()
            streams.1?.close()
        }
    }

    // MARK: - State

    private func set(_ new: State) {
        let changed = lock.withLock { () -> Bool in
            guard state != new, state != .closed else { return false }
            if case .failed = state { return false }
            state = new
            return true
        }
        if changed {
            NSLog("Nearside: phone app \(target): \(new)")
            Trace.log("state \(new)")
        }
        if changed, let onState { Task { @MainActor in onState(new) } }
    }

    private func fail(_ message: String) { set(.failed(message)) }
}

private final class TicketBox: @unchecked Sendable { var value: Data? }
