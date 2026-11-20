// atview: Gate B viewer. Streams phone apps (each on its own virtual display) into Metal windows
// over our native adb and prints latency/throughput stats.
//
//   atview <ip:port> [app …]       app = chrome|maps|youtube|settings|messages|pkg/activity
//   atview <ip:port> --bulk N      throughput: N parallel phone→Mac streams for 6 s
//   atview <ip:port> --ping        idle control round trip
import AppKit
import Foundation
import NativeAdb

setvbuf(stdout, nil, _IOLBF, 0)
let args = CommandLine.arguments.dropFirst()
guard let hostPort = args.first, let colon = hostPort.lastIndex(of: ":"),
      let port = UInt16(hostPort[hostPort.index(after: colon)...]) else {
    print("usage: atview <ip:port> [app …] | --bulk N | --ping"); exit(2)
}
let host = String(hostPort[..<colon])

let apps = [
    "chrome": "com.android.chrome/com.google.android.apps.chrome.Main",
    "maps": "com.google.android.apps.maps/com.google.android.maps.MapsActivity",
    "youtube": "com.google.android.youtube/.app.honeycomb.Shell$HomeActivity",
    "settings": "com.android.settings/.Settings",
    "messages": "com.google.android.apps.messaging/.ui.ConversationListActivity",
]

// The same identity and pin the app uses.
let support = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/Nearside/adbkey").path
let key = (try? AdbKey(pemFile: AdbKey.defaultPath)) ?? (try! AdbKey(pemFile: support))
let pin = UserDefaults(suiteName: "dev.nearside.mac")?.string(forKey: "pairedPhoneKey").flatMap { hex -> Data? in
    var d = Data(); var i = hex.startIndex
    while i < hex.endIndex { let n = hex.index(i, offsetBy: 2); d.append(UInt8(hex[i..<n], radix: 16)!); i = n }
    return d
}
guard let pin else { print("no paired phone in Nearside's settings"); exit(1) }

let connectStart = macMicros()
let adb = try AdbConnection.connect(host: host, port: port, key: key, expectedPeerKey: pin)
print("connected in \((macMicros() - connectStart) / 1000) ms, delayed_ack=\(adb.banner.contains("delayed_ack"))")

// Start the probe server (once; a second copy exits because the socket name is taken).
_ = try adb.shell("P=$(pm path dev.nearside|head -1|cut -d: -f2); CLASSPATH=$P setsid app_process / dev.nearside.helper.probe.StreamProbe </dev/null >/data/local/tmp/stream-probe.log 2>&1 &")

func openProbe(window: Int) throws -> AdbStream {
    for _ in 0..<30 {
        if let s = try? adb.open("localabstract:nearside-probe", window: window) { return s }
        Thread.sleep(forTimeInterval: 0.1)
    }
    throw AdbError.refused("probe")
}

func hello(_ role: Character, _ extra: Data = Data()) -> Data {
    Wire.packet(Wire.hello, Data([role.asciiValue!]) + extra)
}

// MARK: - Throughput and idle ping modes

if args.dropFirst().first == "--bulk" {
    let n = Int(args.dropFirst(2).first ?? "1") ?? 1
    let total = Counter()
    let start = macMicros()
    for _ in 0..<n {
        Thread {
            guard let s = try? openProbe(window: 2 * 1024 * 1024) else { return }
            try? s.write(hello("t"))
            while macMicros() - start < 6_000_000, let d = try? s.read() { total.add(d.count) }
            s.close()
        }.start()
    }
    Thread.sleep(forTimeInterval: 6.5)
    print(String(format: "bulk %d stream(s): %.0f Mbps", n, Double(total.value) * 8 / 6 / 1_000_000))
    exit(0)
}

if args.dropFirst().first == "--ping" {
    let s = try openProbe(window: 64 * 1024)
    try s.write(hello("p"))
    var reader = Wire.Reader()
    var rtts: [Double] = []
    for _ in 0..<50 {
        var body = Data(); body.appendBE(UInt64(macMicros()))
        try s.write(Wire.packet(Wire.ping, body))
        var got = false
        while !got, let d = try s.read() {
            for (type, p) in reader.feed(d) where type == Wire.pong && p.count >= 8 {
                rtts.append(Double(macMicros() - Int64(p.readBE(UInt64.self, at: p.startIndex))) / 1000)
                got = true
            }
        }
        Thread.sleep(forTimeInterval: Double(ProcessInfo.processInfo.environment["PING_MS"] ?? "50")! / 1000)
    }
    print(String(format: "idle RTT p50 %.1f ms, p95 %.1f ms", percentile(rtts, 50), percentile(rtts, 95)))
    exit(0)
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock(); private var n = 0
    func add(_ k: Int) { lock.withLock { n += k } }
    var value: Int { lock.withLock { n } }
    func take() -> Int { lock.withLock { defer { n = 0 }; return n } }
}

// MARK: - Streaming windows

final class Session: NSObject, NSWindowDelegate {
    let name: String
    let stream: AdbStream
    let decoder = VideoDecoder()
    let view: StreamView
    let window: NSWindow
    let clock = ClockSync()
    let writer = DispatchQueue(label: "ctl-writer")
    let bytes = Counter()
    private let statsLock = NSLock()
    private var latencies: [Double] = [], decodeMs: [Double] = [], encodeMs: [Double] = [], networkMs: [Double] = [], showMs: [Double] = [], waitMs: [Double] = [], presented = 0
    private var firstFrameAt: Int64?, startedAt = macMicros()
    private var resizeSentAt: Int64?, resizeGen: UInt32 = 0
    private var videoGen: UInt32 = 0

    init(name: String, component: String, index: Int) throws {
        self.name = name
        let screen = NSScreen.main!.visibleFrame
        // A phone-like window: 1 dp = 1 pt (dpi = 160 × backing scale).
        let scale = NSScreen.main!.backingScaleFactor
        let ptH = (screen.height * 0.8).rounded(), ptW = (ptH * 9 / 20).rounded()
        let pxW = Int(ptW * scale) & ~1, pxH = Int(ptH * scale) & ~1
        stream = try openProbe(window: 2 * 1024 * 1024)
        view = StreamView(frame: NSRect(x: 0, y: 0, width: ptW, height: ptH))
        view.videoSize = CGSize(width: pxW, height: pxH)
        window = NSWindow(contentRect: NSRect(x: screen.minX + 40 + CGFloat(index) * (ptW + 20), y: screen.minY + 40, width: ptW, height: ptH),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        super.init()
        window.title = name
        window.contentView = view
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)

        var h = Data()
        h.appendBE(UInt16(pxW)); h.appendBE(UInt16(pxH)); h.appendBE(UInt16(160 * Int(scale)))
        h.append(60); h.appendBE(UInt32(16_000))
        h.append(Data(component.utf8))
        try stream.write(hello("v", h))

        decoder.onFrame = { [weak self] in self?.view.enqueue($0) }
        view.onPresented = { [weak self] frame, presentedUs in self?.presented(frame, presentedUs) }
        view.onDrawn = { [weak self] frame, drawnUs in
            guard let self else { return }
            self.statsLock.withLock { self.waitMs.append(Double(drawnUs - frame.decodedUs) / 1000) }
        }
        view.onTouch = { [weak self] action, x, y in self?.sendTouch(action, x, y) }
        Thread { [weak self] in self?.readLoop() }.start()
        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.ping() }
        Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.report() }
        // Test hook: ATVIEW_RESIZE_AFTER=<s> resizes the window wider, as a user drag would.
        if let after = ProcessInfo.processInfo.environment["ATVIEW_RESIZE_AFTER"].flatMap(Double.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + after) { [weak self] in
                guard let self else { return }
                var f = self.window.frame
                f.size.width = (f.size.height * 0.8).rounded()
                self.window.setFrame(f, display: true)
                self.windowDidEndLiveResize(Notification(name: NSWindow.didEndLiveResizeNotification))
            }
        }
    }

    private func readLoop() {
        var reader = Wire.Reader()
        while let data = try? stream.read() {
            if reader.overflowed { print("\(name): oversized packet; closing"); stream.close(); break }
            bytes.add(data.count)
            let now = macMicros()
            for (type, p) in reader.feed(data) {
                let s = p.startIndex
                switch type {
                case Wire.config where p.count >= 8:
                    let w = Int(p.readBE(UInt16.self, at: s)), h = Int(p.readBE(UInt16.self, at: s + 2))
                    let gen = p.readBE(UInt32.self, at: s + 4)
                    decoder.configure(annexB: p.subdata(in: s + 8..<p.endIndex), gen: gen)
                    statsLock.withLock { videoGen = gen }
                    DispatchQueue.main.async { self.view.videoSize = CGSize(width: w, height: h) }
                case Wire.frame where p.count >= 21:
                    let gen = p.readBE(UInt32.self, at: s)
                    let pts = Int64(p.readBE(UInt64.self, at: s + 4))
                    let encoded = Int64(p.readBE(UInt64.self, at: s + 12))
                    if let offset = clock.offset {
                        statsLock.withLock {
                            encodeMs.append(Double(encoded - pts) / 1000)
                            networkMs.append(Double(now - (encoded - offset)) / 1000)
                        }
                    }
                    decoder.decode(annexB: p.subdata(in: s + 21..<p.endIndex), ptsUs: pts, gen: gen, receivedUs: now)
                case Wire.pong where p.count >= 16:
                    clock.add(t0: Int64(p.readBE(UInt64.self, at: s)), phone: Int64(p.readBE(UInt64.self, at: s + 8)), t1: now)
                default: break
                }
            }
        }
        print("\(name): stream closed")
    }

    private func presented(_ frame: VideoDecoder.Frame, _ presentedUs: Int64) {
        statsLock.withLock {
            presented += 1
            if firstFrameAt == nil {
                firstFrameAt = presentedUs
                print("\(name): first frame \((presentedUs - startedAt) / 1000) ms after open")
            }
            if let sent = resizeSentAt, frame.gen == resizeGen {
                print("\(name): resize → new layout on screen in \((presentedUs - sent) / 1000) ms")
                resizeSentAt = nil
            }
            if let offset = clock.offset {
                latencies.append(Double(presentedUs - (frame.ptsUs - offset)) / 1000)
            }
            decodeMs.append(Double(frame.decodedUs - frame.receivedUs) / 1000)
            showMs.append(Double(presentedUs - frame.decodedUs) / 1000)
        }
    }

    private func send(_ packet: Data) {
        writer.async { [stream] in try? stream.write(packet) }
    }

    private func sendTouch(_ action: Int, _ x: Float, _ y: Float) {
        var b = Data([UInt8(action)])
        b.appendBE(statsLock.withLock { videoGen }); b.appendBE(x); b.appendBE(y)
        send(Wire.packet(Wire.touch, b))
    }

    private func ping() {
        var b = Data(); b.appendBE(UInt64(macMicros()))
        send(Wire.packet(Wire.ping, b))
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        // Wait for the hand to settle, then give the phone the window's exact pixel size.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [self] in
            let scale = window.backingScaleFactor
            let size = view.bounds.size
            var w = Int(size.width * scale) & ~1, h = Int(size.height * scale) & ~1
            let longSide = max(w, h)
            if longSide > 2400 { w = w * 2400 / longSide & ~1; h = h * 2400 / longSide & ~1 }
            let dpi = Int(160 * scale * CGFloat(w) / (size.width * scale))
            var b = Data(); b.appendBE(UInt16(w)); b.appendBE(UInt16(h)); b.appendBE(UInt16(dpi))
            statsLock.withLock { resizeSentAt = macMicros(); resizeGen = videoGen + 1 }
            send(Wire.packet(Wire.resize, b))
            print("\(name): resize to \(w)x\(h)@\(dpi)")
        }
    }

    func windowWillClose(_ notification: Notification) { stream.close() }

    private func report() {
        let wait = statsLock.withLock { waitMs }
        let (lat, dec, n, enc, net, show) = statsLock.withLock { () -> ([Double], [Double], Int, [Double], [Double], [Double]) in
            defer { latencies.removeAll(); decodeMs.removeAll(); presented = 0; encodeMs.removeAll(); networkMs.removeAll(); showMs.removeAll(); waitMs.removeAll() }
            return (latencies, decodeMs, presented, encodeMs, networkMs, showMs)
        }
        print(String(format: "%@: stages p50 — encode %.0f, network %.0f, decode %.1f, wait-for-draw %.1f, to-screen %.0f ms",
                     name, percentile(enc, 50), percentile(net, 50), percentile(dec, 50), percentile(wait, 50), percentile(show, 50)))
        let rtt = clock.takeRTTs()
        print(String(format: "%@: %.0f fps, %.1f Mbps, capture→present p50 %.0f p95 %.0f ms, decode %.1f ms, ctl RTT p50 %.0f p95 %.0f ms, dropped %d",
                     name, Double(n) / 3, Double(bytes.take()) * 8 / 3 / 1_000_000, percentile(lat, 50), percentile(lat, 95),
                     dec.isEmpty ? .nan : dec.reduce(0, +) / Double(dec.count), percentile(rtt, 50), percentile(rtt, 95), view.dropped))
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
var sessions: [Session] = []
for (i, name) in args.dropFirst().enumerated() {
    do {
        sessions.append(try Session(name: name, component: apps[name] ?? name, index: i))
    } catch {
        print("\(name): \(error)")
    }
}
app.activate()
app.run()
