import CoreGraphics
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
        case closed
    }

    public let target: String
    /// Decoded frames, on VideoToolbox's thread.
    public var onFrame: (@Sendable (VideoDecoder.Frame) -> Void)?
    /// State changes, on the main thread.
    public var onState: (@MainActor @Sendable (State) -> Void)?
    /// The video's pixel size (it changes after a resize), on the main thread.
    public var onVideoSize: (@MainActor @Sendable (CGSize) -> Void)?

    private let requestTicket: @Sendable () async -> Data?
    private let token: String
    private let id: Data
    private let lock = NSLock()
    private var control: AdbStream?
    private var video: AdbStream?
    private var state: State = .opening
    private var gen: UInt32 = 0
    private var closing = false
    private var size: (width: Int, height: Int, dpi: Int)
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

    init(target: String, width: Int, height: Int, dpi: Int, fps: Int = 60, kbps: Int = 12_000,
         token: String, requestTicket: @escaping @Sendable () async -> Data?) {
        self.target = target
        self.size = (width & ~1, height & ~1, dpi)
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
            case .error(_, let text): fail(text.isEmpty ? "The app couldn't be opened." : text)
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
                    decoder.decode(annexB: data, gen: gen, ptsMicros: pts, receivedMicros: now)
                default: break
                }
            }
            if reader.failed { break }
        }
        streamEnded(stream)
    }

    /// A stream dropped without us closing it: try to resume for a while, then give up.
    private func streamEnded(_ stream: AdbStream) {
        let resume = lock.withLock { () -> Bool in
            guard control === stream || video === stream, !closing else { return false }
            control?.close(); video?.close()
            control = nil; video = nil
            switch state {
            case .gone, .failed, .closed: return false
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
        Trace.log("touch \(action) p\(pointer) \(x) \(y) gen \(gen)")
        send(DisplayWire.touch(action, pointer: pointer, gen: gen, x: x, y: y, micros: UInt64(max(0, time) * 1_000_000)))
    }

    public func touches(_ touches: [PointerGestures.Touch], time: TimeInterval) {
        for t in touches { touch(t.action, pointer: t.pointer, x: t.x, y: t.y, time: time) }
    }

    /// A mouse wheel at x/y (normalised); h/v in notches, + = right/up.
    public func scroll(x: Float, y: Float, h: Float, v: Float) {
        send(DisplayWire.scroll(gen: lock.withLock { gen }, x: x, y: y, h: h, v: v))
    }

    /// The mouse pointer itself: hover, and the right button.
    public func mouse(_ action: DisplayWire.MouseAction, x: Float, y: Float) {
        send(DisplayWire.mouse(action, gen: lock.withLock { gen }, x: x, y: y))
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

    /// The window's new pixel size; the phone re-lays the app out for it.
    public func resize(width: Int, height: Int, dpi: Int) {
        lock.withLock { size = (width & ~1, height & ~1, dpi) }
        send(DisplayWire.resize(width: width & ~1, height: height & ~1, dpi: dpi))
    }

    /// Hidden windows stop the video (the app keeps running).
    public func setVisible(_ visible: Bool) {
        send(DisplayWire.packet(DisplayWire.visibility, Data([visible ? 0 : 1])))
        DispatchQueue.main.async { [self] in
            self.visible = visible
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

    /// Closes the window's session; the app goes back to the phone, under what's showing there.
    public func close() {
        DispatchQueue.main.async { [self] in pinger?.invalidate() }
        let streams = lock.withLock { () -> (AdbStream?, AdbStream?) in
            closing = true
            state = .closed
            return (control, video)
        }
        writer.async {
            try? streams.0?.write(DisplayWire.packet(DisplayWire.close))
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
