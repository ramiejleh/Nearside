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
    /// Phone window: its apps (top first), and their pictures as they come, on the main thread.
    public var onTasks: (@MainActor @Sendable ([PhoneTask]) -> Void)?
    public var onSnapshot: (@MainActor @Sendable (Int32, Data) -> Void)?
    /// Rows at the top of the display the window doesn't show (the phone's status bar there),
    /// on the main thread.
    public var onCrop: (@MainActor @Sendable (Int) -> Void)?
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
    /// Top rows of the display the window doesn't show (the status bar's); input maps past them.
    private var cropPixels = 0
    private let fps: Int
    private let kbps: Int
    /// The window's sound plays on the Mac (else it stays on the phone).
    private let soundOnMac: Bool
    private let writer = DispatchQueue(label: "phone-app-control", qos: .userInteractive)
    private let decoder = VideoDecoder()
    /// phone µs − Mac µs, from the lowest-RTT ping so far (for latency stats).
    private var clockOffset: Int64?
    private var bestRTT = Int64.max
    /// The statistics overlay's numbers since it last asked (see `takeStats`).
    private var stats = Stats()
    private var pinger: Timer?

    static let socket = "localabstract:nearside-display"
    static let graceSeconds: TimeInterval = 30

    init(target: String, width: Int, height: Int, dpi: Int, fps: Int = 60, kbps: Int = 12_000, soundOnMac: Bool = true,
         token: String, requestTicket: @escaping @Sendable () async -> Data?) {
        self.target = target
        self.size = (width & ~1, height & ~1, dpi)
        self.fps = fps
        self.kbps = kbps
        self.soundOnMac = soundOnMac
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
        Native.windowOpened()
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
        guard semaphore.wait(timeout: .now() + 5) == .success, let ticket = box.value else {
            NSLog("Nearside: phone app \(target): no ticket from the phone (its helper didn't answer)")
            return false
        }
        guard let adb = Native.current() else { NSLog("Nearside: phone app \(target): not connected"); return false }
        do {
            let ctl = try adb.open(Self.socket, window: 256 * 1024)
            try ctl.write(DisplayWire.hello(role: .control, session: id, ticket: ticket, token: token))
            // Nothing goes out (no app name, no input) and nothing is shown until the other end
            // proves it's our helper, not something squatting the socket name.
            guard let ctlStart = awaitServer(ctl, role: .control, ticket: ticket) else {
                NSLog("Nearside: phone app \(target): the phone's display server didn't answer")
                ctl.close(); return false
            }
            if resume {
                try ctl.write(DisplayWire.packet(DisplayWire.resume))
            } else {
                let s = lock.withLock { size }
                try ctl.write(DisplayWire.open(width: s.width, height: s.height, dpi: s.dpi, fps: fps, kbps: kbps, target: target))
            }
            if !soundOnMac { try ctl.write(DisplayWire.packet(DisplayWire.sound, Data([0]))) }
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
            if let dock = lock.withLock({ dock }) { try ctl.write(DisplayWire.utf8(DisplayWire.dock, dock.joined(separator: "\n"))) }
            DispatchQueue.main.async { [self] in reconsiderPinging(force: true) }
            Self.interactive { [self] in readControl(ctl, ctlStart) }
            Self.interactive { [self] in readVideo(vid, vidStart) }
            if soundOnMac { Self.interactive { [self] in openAudio(adb, ticket) } }
            return true
        } catch {
            NSLog("Nearside: phone app \(target): connecting failed (\(error))")
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
            case .tasks(let list):
                if let onTasks { Task { @MainActor in onTasks(list) } }
            case let .snapshot(task, jpeg):
                if let onSnapshot { Task { @MainActor in onSnapshot(task, jpeg) } }
            case .secure(let on):
                if let onSecure { Task { @MainActor in onSecure(on) } }
            case .insets(let top, _):
                lock.withLock { cropPixels = top }
                if let onCrop { Task { @MainActor in onCrop(top) } }
            case .thermal(let reduced):
                if let onThermal { Task { @MainActor in onThermal(reduced) } }
            case let .pong(t0, phone):
                let now = monotonicMicros(), rtt = now - Int64(t0)
                lock.withLock {
                    if rtt < bestRTT { bestRTT = rtt; clockOffset = Int64(phone) - (Int64(t0) + now) / 2 }
                    stats.rttMicros = rtt
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
                    lock.withLock {
                        stats.frames += 1
                        stats.bytes += data.count
                        stats.encodeMicros += max(encoded - pts, 0)
                        if let offset = clockOffset {
                            let latency = max(now - (pts - offset), 0)
                            stats.latencyMicros += latency
                            stats.latencyMaxMicros = max(stats.latencyMaxMicros, latency)
                            stats.latencyCount += 1
                        }
                    }
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

    /// What arrived since the last call (the statistics overlay asks once a second).
    public func takeStats() -> Stats {
        lock.withLock {
            var taken = stats
            taken.seconds = Double(monotonicMicros() - stats.since) / 1_000_000
            stats = Stats(rttMicros: stats.rttMicros)
            return taken
        }
    }

    /// Numbers for the statistics overlay.
    public struct Stats: Sendable {
        var since = monotonicMicros()
        public var seconds = 0.0
        public var frames = 0
        public var bytes = 0
        var encodeMicros: Int64 = 0
        var latencyMicros: Int64 = 0
        var latencyMaxMicros: Int64 = 0
        var latencyCount = 0
        /// The last ping's round trip.
        public var rttMicros: Int64 = 0

        init(rttMicros: Int64 = 0) { self.rttMicros = rttMicros }

        public var fps: Double { seconds > 0 ? Double(frames) / seconds : 0 }
        public var mbps: Double { seconds > 0 ? Double(bytes) * 8 / seconds / 1_000_000 : 0 }
        /// The phone capturing a frame → it arriving here, ms (average, worst); nil before the clocks are matched.
        public var latencyMs: (average: Int, worst: Int)? {
            latencyCount > 0 ? (Int(latencyMicros / Int64(latencyCount) / 1000), Int(latencyMaxMicros / 1000)) : nil
        }
        public var encodeMs: Int { frames > 0 ? Int(encodeMicros / Int64(frames) / 1000) : 0 }
    }

    /// Test hook: NEARSIDE_TEST_VIDEO_KBPS=<n> reads video no faster than that (a slow network).
    private static let testKbps = Double(ProcessInfo.processInfo.environment["NEARSIDE_TEST_VIDEO_KBPS"] ?? "")

    private static func throttleForTesting(_ bytes: Int) {
        guard let kbps = testKbps, kbps > 0 else { return }
        Thread.sleep(forTimeInterval: Double(bytes) * 8 / (kbps * 1000))
    }

    /// A reader thread at interactive priority (frames, input replies and sound must not wait).
    private static func interactive(_ body: @escaping @Sendable () -> Void) {
        let thread = Thread(block: body)
        thread.qualityOfService = .userInteractive
        thread.start()
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
                    if data.isEmpty { player.silence() }
                    else { player.play(data, ptsMicros: pts, receivedMicros: monotonicMicros()) }
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
        guard let stream = lock.withLock({ () -> AdbStream? in lastSentMicros = monotonicMicros(); return control }) else { return }
        writer.async { try? stream.write(packet) }
    }

    /// x/y normalised (0…1) within the video; `time` is the Mac event's (NSEvent.timestamp, s).
    public func touch(_ action: DisplayWire.TouchAction, pointer: UInt8 = 0, x: Float, y: Float,
                      time: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        noteInput()
        let gen = lock.withLock { self.gen }
        let y = displayY(y)
        Trace.log("touch \(action) p\(pointer) \(x) \(y) gen \(gen)")
        send(DisplayWire.touch(action, pointer: pointer, gen: gen, x: x, y: y, micros: UInt64(max(0, time) * 1_000_000)))
    }

    /// Fingers that changed together (a pinch step): one packet, so the phone moves them as one.
    public func touches(_ touches: [PointerGestures.Touch], time: TimeInterval) {
        guard touches.count > 1 else {
            for t in touches { touch(t.action, pointer: t.pointer, x: t.x, y: t.y, time: time) }
            return
        }
        noteInput()
        let gen = lock.withLock { self.gen }
        let list = touches.map { (action: $0.action, pointer: $0.pointer, x: $0.x, y: displayY($0.y)) }
        send(DisplayWire.touches(list, gen: gen, micros: UInt64(max(0, time) * 1_000_000)))
    }

    /// A mouse wheel at x/y (normalised); h/v in notches, + = right/up.
    public func scroll(x: Float, y: Float, h: Float, v: Float) {
        noteInput()
        send(DisplayWire.scroll(gen: lock.withLock { gen }, x: x, y: displayY(y), h: h, v: v))
    }

    /// The mouse pointer itself: hover, and the right button.
    public func mouse(_ action: DisplayWire.MouseAction, x: Float, y: Float) {
        noteInput(pointerInside: action != .exit)
        send(DisplayWire.mouse(action, gen: lock.withLock { gen }, x: x, y: displayY(y)))
    }

    public func back() { send(DisplayWire.packet(DisplayWire.nav, Data([1]))) }

    // Phone window
    public func home() { send(DisplayWire.packet(DisplayWire.nav, Data([2]))) }
    /// Asks for the window's apps (onTasks), then their pictures (onSnapshot).
    public func requestRecents() { send(DisplayWire.packet(DisplayWire.recents)) }
    public func bringToFront(task: Int32) { send(DisplayWire.task(DisplayWire.taskFront, task)) }
    public func remove(task: Int32) { send(DisplayWire.task(DisplayWire.taskRemove, task)) }
    /// The home screen's dock: packages, at most 5 shown.
    public func setDock(_ packages: [String]) {
        lock.withLock { dock = packages }
        send(DisplayWire.utf8(DisplayWire.dock, packages.joined(separator: "\n")))
    }
    private var dock: [String]?

    // MARK: Keyboard

    public func keys(_ keys: [KeyMap.Key]) { noteInput(); keys.forEach { send(DisplayWire.key($0)) } }

    /// Typed text (the Mac's layout already applied).
    public func text(_ text: String) { noteInput(); send(DisplayWire.utf8(DisplayWire.text, text)) }

    /// ⌘V: the Mac's clipboard text (nil: paste what the phone has).
    public func paste(_ text: String?) { send(DisplayWire.utf8(DisplayWire.paste, text ?? "")) }

    /// The Mac's keyboard layout ("Danish\nda"), so the phone can type every character it can.
    /// Opens a phone notification in this window (its app is the window's), as tapping it would.
    public func openNotification(_ key: String) {
        send(DisplayWire.utf8(DisplayWire.notification, key))
    }

    /// Files already pushed to the app's shared folder: the app in the window gets them as a share.
    public func share(_ names: [String]) {
        send(DisplayWire.utf8(DisplayWire.share, names.joined(separator: "\n")))
    }

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
    public func resize(width: Int, height: Int, dpi: Int) {
        lock.withLock { size = (width & ~1, height & ~1, dpi) }
        send(DisplayWire.resize(width: width & ~1, height: height & ~1, dpi: dpi))
    }

    /// Hidden windows stop the video (the app keeps running).
    /// How much of the phone's encoder the window gets: the window in use full rate, others on
    /// screen less, hidden ones nothing (the app keeps running).
    public enum Visibility: UInt8, Sendable { case focused = 0, hidden = 1, visible = 2 }

    public func setVisibility(_ visibility: Visibility) {
        send(DisplayWire.packet(DisplayWire.visibility, Data([visibility.rawValue])))
        DispatchQueue.main.async { [self] in
            level = visibility
            reconsiderPinging()
        }
    }

    // MARK: - Ping
    //
    // A ping every 40 ms keeps the phone's Wi-Fi out of power save: idle, it dozes within ~100 ms
    // and the next touch then waits for its next wake-up (measured: round trip p95 177 ms pinging
    // once a second, 111 ms at 100 ms, 17 ms at 50 ms). That costs the phone's battery, so it's
    // only done while the window is likely to get input next (PingPolicy); otherwise the pings
    // just keep the session alive (the phone gives up on a Mac silent for 15 s).

    @MainActor private var level: Visibility = .focused
    @MainActor private var pointerInside = false
    @MainActor private var lastInput: TimeInterval = 0
    @MainActor private var pingInterval: TimeInterval = 0
    /// When anything last went to the phone (µs): a ping right after is redundant.
    private var lastSentMicros: Int64 = 0

    @MainActor private func reconsiderPinging(force: Bool = false) {
        let want = PingPolicy.interval(level: level, pointerInside: pointerInside,
                                       sinceInput: ProcessInfo.processInfo.systemUptime - lastInput)
        guard force || want != pingInterval else { return }
        pingInterval = want
        pinger?.invalidate()
        guard !lock.withLock({ closing }) else { return }
        pinger = Timer.scheduledTimer(withTimeInterval: want, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pingTick() }
        }
        pinger?.tolerance = want < 1 ? 0.005 : want / 10
    }

    @MainActor private func pingTick() {
        reconsiderPinging() // input may have gone quiet: slower
        let now = monotonicMicros()
        if pingInterval < 1, now - lock.withLock({ lastSentMicros }) < 35_000 { return } // input kept it awake
        send(DisplayWire.ping(UInt64(now)))
    }

    /// Input, or the pointer coming in or leaving (nil: unchanged): pinging may need to speed up.
    private func noteInput(pointerInside inside: Bool? = nil) {
        DispatchQueue.main.async { [self] in
            lastInput = ProcessInfo.processInfo.systemUptime
            if let inside { pointerInside = inside }
            reconsiderPinging()
        }
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
        Native.windowClosed()
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

    private func fail(_ message: String) {
        NSLog("Nearside: phone app \(target): failed: \(message)")
        set(.failed(message))
    }
}

private final class TicketBox: @unchecked Sendable { var value: Data? }

/// How often a window pings the phone. Fast pings keep the phone's Wi-Fi awake so a touch gets
/// there at once, at a cost to its battery: so only for the window in use (focused) while the
/// pointer is over it or something was typed or touched in the last 10 s.
public enum PingPolicy {
    public static func interval(level: PhoneAppSession.Visibility, pointerInside: Bool, sinceInput: TimeInterval) -> TimeInterval {
        switch level {
        case .hidden: 5
        case .visible: 1
        case .focused: pointerInside || sinceInput < 10 ? 0.04 : 1
        }
    }
}
