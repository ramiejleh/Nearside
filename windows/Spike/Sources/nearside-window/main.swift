// The phone window on Windows, for Phase 3: the engine opens the phone's home screen, FFmpeg
// decodes its H.264 (software here; a VM has no GPU), GDI draws it, and the left mouse button
// is a finger. Prints frame rate, bitrate, latency and decode time every 2 s.
//   nearside-window [width height dpi]   (default 720 1600 320)
#if os(Windows)
import CFFmpeg
import Foundation
import NearsideCore
import WindowsPlatform
import WinSDK

// MARK: - Decoding

/// A decoded picture, as top-down BGRA rows (what GDI draws).
struct WindowFrame: VideoFrame {
    let bgra: Data
    let width: Int
    let height: Int
    let gen: UInt32
    let ptsMicros: Int64
    let receivedMicros: Int64

    /// 64 points, all near black (as the Mac samples its luma plane).
    func isBlack() -> Bool {
        bgra.withUnsafeBytes { raw in
            for i in 0..<8 { for j in 0..<8 {
                let x = width * (2 * i + 1) / 16, y = height * (2 * j + 1) / 16
                let p = (y * width + x) * 4
                if raw[p] >= 24 || raw[p + 1] >= 24 || raw[p + 2] >= 24 { return false }
            } }
            return true
        }
    }
}

/// H.264 (or HEVC) with FFmpeg's software decoder, frames converted to BGRA. Safe from any
/// thread: a reconnecting window's old reader may still be decoding when the new one configures,
/// so FFmpeg's state is only touched under `state` (and frames are handed out after it).
final class FFmpegDecoder: VideoDecoding, @unchecked Sendable {
    let codec: DisplayWire.Codec
    private var currentGen: UInt32 = 0
    var gen: UInt32 { state.withLock { currentGen } }
    var onFrame: (@Sendable (any VideoFrame) -> Void)?
    private var context: UnsafeMutablePointer<AVCodecContext>?
    private var packet = av_packet_alloc()
    private var frame = av_frame_alloc()
    private var converted = av_frame_alloc()
    private var scaler: UnsafeMutablePointer<SwsContext>?
    /// Sent ahead of the next frame (the decoder learns the stream from them).
    private var pendingConfig: Data?
    /// Guards everything FFmpeg owns (context, packet, frames, scaler, gen).
    private let state = NSLock()
    /// Decode time totals since the stats last asked.
    private let lock = NSLock()
    private var decodeMicros: Int64 = 0, decoded = 0

    init(codec: DisplayWire.Codec) { self.codec = codec }

    deinit {
        invalidate()
        av_packet_free(&packet); av_frame_free(&frame); av_frame_free(&converted)
    }

    func invalidate() { state.withLock { freeLocked() } }

    private func freeLocked() {
        if context != nil { avcodec_free_context(&context) }
        if let scaler { sws_freeContext(scaler) }
        scaler = nil
    }

    @discardableResult
    func configure(parameterSets annexB: Data, gen: UInt32) -> Bool {
        state.lock()
        defer { state.unlock() }
        freeLocked()
        guard let decoder = avcodec_find_decoder(codec == .h264 ? AV_CODEC_ID_H264 : AV_CODEC_ID_HEVC),
              let context = avcodec_alloc_context3(decoder) else { return false }
        context.pointee.flags |= Int32(AV_CODEC_FLAG_LOW_DELAY)
        // Slices in parallel, never whole frames (that would hold each frame back by one).
        context.pointee.thread_count = 0
        context.pointee.thread_type = Int32(FF_THREAD_SLICE)
        guard avcodec_open2(context, decoder, nil) == 0 else {
            var context: UnsafeMutablePointer<AVCodecContext>? = context
            avcodec_free_context(&context)
            return false
        }
        self.context = context
        currentGen = gen
        pendingConfig = annexB
        return true
    }

    func decode(annexB: Data, gen: UInt32, ptsMicros: Int64, receivedMicros: Int64) {
        let pictures = state.withLock { decodeLocked(annexB, gen: gen, ptsMicros: ptsMicros, receivedMicros: receivedMicros) }
        pictures.forEach { onFrame?($0) } // outside the lock: the callback may take its time
    }

    private func decodeLocked(_ annexB: Data, gen: UInt32, ptsMicros: Int64, receivedMicros: Int64) -> [WindowFrame] {
        guard gen == currentGen, let context, let packet, let frame, let converted else { return [] }
        var pictures: [WindowFrame] = []
        var data = annexB
        if let config = pendingConfig { data = config + annexB; pendingConfig = nil }
        let started = monotonicMicros()
        guard av_new_packet(packet, Int32(data.count)) == 0 else { return [] }
        data.withUnsafeBytes { packet.pointee.data.update(from: $0.bindMemory(to: UInt8.self).baseAddress!, count: data.count) }
        packet.pointee.pts = ptsMicros
        let sent = avcodec_send_packet(context, packet)
        av_packet_unref(packet)
        guard sent == 0 else { return [] }
        while avcodec_receive_frame(context, frame) == 0 {
            let w = Int(frame.pointee.width), h = Int(frame.pointee.height)
            scaler = sws_getCachedContext(scaler, Int32(w), Int32(h), AVPixelFormat(frame.pointee.format),
                                          Int32(w), Int32(h), AV_PIX_FMT_BGRA, Int32(SWS_POINT.rawValue), nil, nil, nil)
            av_frame_unref(converted)
            converted.pointee.width = Int32(w); converted.pointee.height = Int32(h)
            converted.pointee.format = AV_PIX_FMT_BGRA.rawValue
            guard scaler != nil, av_frame_get_buffer(converted, 0) == 0, sws_scale_frame(scaler, converted, frame) >= 0,
                  let rows = converted.pointee.data.0 else { av_frame_unref(frame); continue }
            let stride = Int(converted.pointee.linesize.0)
            var bgra = Data(count: w * h * 4)
            bgra.withUnsafeMutableBytes { out in
                for y in 0..<h { (out.baseAddress! + y * w * 4).copyMemory(from: rows + y * stride, byteCount: w * 4) }
            }
            av_frame_unref(frame)
            lock.withLock { decodeMicros += monotonicMicros() - started; decoded += 1 }
            pictures.append(WindowFrame(bgra: bgra, width: w, height: h, gen: gen, ptsMicros: ptsMicros, receivedMicros: receivedMicros))
        }
        return pictures
    }

    /// Average decode (and convert) time per frame since the last call, ms.
    func takeDecodeMs() -> Double {
        lock.withLock {
            defer { decodeMicros = 0; decoded = 0 }
            return decoded > 0 ? Double(decodeMicros) / Double(decoded) / 1000 : 0
        }
    }
}

// MARK: - The window

/// The newest picture, shared between the decoder's thread and the window's.
final class Latest: @unchecked Sendable {
    private let lock = NSLock()
    private var frame: WindowFrame?
    var value: WindowFrame? {
        get { lock.withLock { frame } }
        set { lock.withLock { frame = newValue } }
    }
}

nonisolated(unsafe) var window: HWND?
nonisolated(unsafe) var session: PhoneAppSession?
nonisolated(unsafe) var decoders: [FFmpegDecoder] = []
let latest = Latest()
nonisolated(unsafe) var fingerDown = false

func clientSize() -> (Int, Int) {
    var rect = RECT()
    GetClientRect(window, &rect)
    return (Int(rect.right - rect.left), Int(rect.bottom - rect.top))
}

/// The mouse position as 0…1 of the picture.
func position(_ lParam: LPARAM) -> (Float, Float) {
    let x = Int16(truncatingIfNeeded: lParam & 0xFFFF), y = Int16(truncatingIfNeeded: (lParam >> 16) & 0xFFFF)
    let (w, h) = clientSize()
    return (min(max(Float(x) / Float(max(w, 1)), 0), 1), min(max(Float(y) / Float(max(h, 1)), 0), 1))
}

func paint() {
    var ps = PAINTSTRUCT()
    let dc = BeginPaint(window, &ps)
    defer { EndPaint(window, &ps) }
    guard let frame = latest.value else { return }
    let (w, h) = clientSize()
    var info = BITMAPINFO()
    info.bmiHeader.biSize = DWORD(MemoryLayout<BITMAPINFOHEADER>.size)
    info.bmiHeader.biWidth = LONG(frame.width)
    info.bmiHeader.biHeight = -LONG(frame.height) // top-down rows
    info.bmiHeader.biPlanes = 1
    info.bmiHeader.biBitCount = 32
    info.bmiHeader.biCompression = DWORD(BI_RGB)
    SetStretchBltMode(dc, HALFTONE)
    _ = frame.bgra.withUnsafeBytes {
        StretchDIBits(dc, 0, 0, Int32(w), Int32(h), 0, 0, Int32(frame.width), Int32(frame.height),
                      $0.baseAddress, &info, UINT(DIB_RGB_COLORS), SRCCOPY)
    }
}

nonisolated(unsafe) let windowProc: WNDPROC = { hwnd, message, wParam, lParam in
    switch Int32(message) {
    case WM_PAINT:
        paint()
        return 0
    case WM_ERASEBKGND:
        return 1 // the picture covers it all: no flicker
    case WM_SIZE:
        // Redraw the last picture at the new size now: a still phone screen sends no new frame.
        InvalidateRect(hwnd, nil, false)
        return 0
    case WM_LBUTTONDOWN:
        SetCapture(hwnd)
        fingerDown = true
        let (x, y) = position(lParam)
        session?.touch(.down, x: x, y: y)
        return 0
    case WM_MOUSEMOVE where fingerDown:
        let (x, y) = position(lParam)
        session?.touch(.move, x: x, y: y)
        return 0
    case WM_LBUTTONUP where fingerDown:
        fingerDown = false
        ReleaseCapture()
        let (x, y) = position(lParam)
        session?.touch(.up, x: x, y: y)
        return 0
    case WM_DESTROY:
        session?.close()
        PostQuitMessage(0)
        return 0
    default:
        return DefWindowProcW(hwnd, message, wParam, lParam)
    }
}

func openWindow(width: Int, height: Int) {
    let name = Array("NearsidePhone".utf16) + [0]
    name.withUnsafeBufferPointer { className in
        var wc = WNDCLASSEXW()
        wc.cbSize = UINT(MemoryLayout<WNDCLASSEXW>.size)
        wc.lpfnWndProc = windowProc
        wc.hInstance = GetModuleHandleW(nil)
        wc.hCursor = LoadCursorW(nil, UnsafePointer(bitPattern: 32512)) // IDC_ARROW
        wc.lpszClassName = className.baseAddress
        RegisterClassExW(&wc)
        // The client area at the picture's shape, 900 px tall (a phone on a laptop screen).
        let clientH = 900, clientW = clientH * width / height
        var rect = RECT(left: 0, top: 0, right: LONG(clientW), bottom: LONG(clientH))
        AdjustWindowRect(&rect, DWORD(WS_OVERLAPPEDWINDOW), false)
        let title = Array("Nearside: phone".utf16) + [0]
        window = title.withUnsafeBufferPointer {
            CreateWindowExW(0, className.baseAddress, $0.baseAddress, DWORD(WS_OVERLAPPEDWINDOW),
                            CW_USEDEFAULT, CW_USEDEFAULT, rect.right - rect.left, rect.bottom - rect.top,
                            nil, nil, wc.hInstance, nil)
        }
        ShowWindow(window, SW_SHOW)
    }
}

// MARK: - Main

setvbuf(stdout, nil, _IONBF, 0)
let args = CommandLine.arguments.dropFirst().compactMap { Int($0) }
let (width, height, dpi) = args.count == 3 ? (args[0], args[1], args[2]) : (720, 1600, 320)

let platform = WindowsPlatform()
platform.videoDecoder = { codec in
    let decoder = FFmpegDecoder(codec: codec)
    decoders.append(decoder)
    return decoder
}
Platforms.current = platform
openWindow(width: width, height: height)

MainActor.assumeIsolated {
    let engine = SyncEngine(apkURL: nil)
    engine.start()
    var state = ""
    Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
        MainActor.assumeIsolated {
            let now = "\(engine.state)\(engine.appLinked ? ", phone app linked" : "")"
            if now != state { state = now; print("engine: \(now)") }
            guard session == nil, engine.state == .connected, engine.appLinked else { return }
            let s = engine.makePhoneWindowSession(width: width, height: height, dpi: dpi)
            s.onFrame = { frame in
                guard let frame = frame as? WindowFrame else { return }
                latest.value = frame
                InvalidateRect(window, nil, false)
            }
            s.onState = { print("window: \($0)") }
            session = s
            s.start()
            print("opening the phone's home screen at \(width)x\(height), \(dpi) dpi")
        }
    }
    Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
        MainActor.assumeIsolated {
            guard let s = session else { return }
            let stats = s.takeStats()
            let decode = decoders.last?.takeDecodeMs() ?? 0
            let latency = stats.latencyMs.map { "\($0.average) ms (worst \($0.worst))" } ?? "matching clocks"
            print(String(format: "%.0f fps, %.1f Mbit/s, phone to here %@, decode %.1f ms, rtt %d ms",
                         stats.fps, stats.mbps, latency as NSString, decode, Int(stats.rttMicros / 1000)))
        }
    }
}

// Windows messages and the engine's run loop on this one thread: wait for either, briefly.
var message = MSG()
loop: while true {
    MsgWaitForMultipleObjects(0, nil, false, 4, DWORD(QS_ALLINPUT))
    while PeekMessageW(&message, nil, 0, 0, UINT(PM_REMOVE)) {
        if message.message == UINT(WM_QUIT) { break loop }
        TranslateMessage(&message)
        DispatchMessageW(&message)
    }
    RunLoop.main.run(mode: .default, before: Date())
}
#else
print("nearside-window runs on Windows only")
#endif
