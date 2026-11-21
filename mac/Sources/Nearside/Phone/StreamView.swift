import NearsideCore
import AppKit
import CoreImage
import CoreVideo
import Metal
import QuartzCore

/// Draws a phone app's frames with Metal, from any thread.
///
/// Wi-Fi delivers frames in bunches (12 % of receive gaps > 25 ms), and drawn the moment they
/// arrived with vsync off, two frames often landed in one screen refresh: only 62 % of refreshes
/// showed a new frame (user: stutter). Two ways to draw, by the "Motion" setting (measured with a
/// 60 fps animation, receive → on screen):
///  - Smooth (default): vsync on, frames queue in the drawables: 98 % of refreshes, +~45 ms.
///  - Responsive: vsync off, paced to the display link: a frame arriving when this refresh
///    already has one waits for the next (at most 2 waiting, trimmed if it stays behind):
///    82 %, +~16 ms.
final class MetalRenderer: @unchecked Sendable {
    let layer = CAMetalLayer()
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private var textureCache: CVMetalTextureCache?
    private let lock = NSLock()
    private var latest: VideoDecoder.Frame?
    private var crop = 0
    // Pacing (under `pace`): frames waiting for the next refresh, when the last refresh began
    // (display-link tick), whether this refresh has shown a frame, how long the queue stayed full.
    private let pace = NSLock()
    private var waiting: [VideoDecoder.Frame] = []
    private var shownThisRefresh = false
    private var backlogTicks = 0
    private var ticking = false
    /// Settings → Phone apps → Motion ("PhoneApps.motion": smooth | responsive), when the window opens.
    let smooth = UserDefaults.standard.string(forKey: "PhoneApps.motion") != "responsive"

    /// Top rows of each frame not to show (an app's empty band; see PhoneDisplaySize).
    var cropPixels: Int {
        get { lock.withLock { crop } }
        set { lock.withLock { crop = newValue }; redraw() }
    }

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
              let pipeline = Self.makePipeline(device) else { return nil }
        self.queue = queue
        self.pipeline = pipeline
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
        layer.displaySyncEnabled = smooth // responsive: paced to the display instead (show/tick)
        layer.maximumDrawableCount = 2
        layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        layer.backgroundColor = CGColor(gray: 0, alpha: 1)
        CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)
    }

    /// The newest frame, if any.
    var lastFrame: VideoDecoder.Frame? { lock.withLock { latest } }

    func show(_ frame: VideoDecoder.Frame) {
        let now: Bool = pace.withLock {
            // Smooth: vsync paces. Without a display link yet (not on screen): draw at once.
            guard !smooth, ticking else { return true }
            if !shownThisRefresh, waiting.isEmpty { shownThisRefresh = true; return true }
            waiting.append(frame)
            if waiting.count > 2 { waiting.removeFirst() } // too far behind: skip the oldest
            return false
        }
        if now {
            lock.withLock { latest = frame }
            draw(frame)
        }
    }

    /// A new screen refresh (the view's display link, main thread): the oldest waiting frame.
    func tick() {
        let next: VideoDecoder.Frame? = pace.withLock {
            ticking = true
            shownThisRefresh = false
            // Still a frame behind after a while: drop one, back to drawing on arrival.
            backlogTicks = waiting.count > 1 ? backlogTicks + 1 : 0
            if backlogTicks > 30, waiting.count > 1 { waiting.removeFirst(); backlogTicks = 0 }
            guard !waiting.isEmpty else { return nil }
            shownThisRefresh = true
            return waiting.removeFirst()
        }
        guard let next else { return }
        DispatchQueue.global(qos: .userInteractive).async { [self] in
            lock.withLock { latest = next }
            draw(next)
        }
    }

    /// The window left the screen: no ticks, so draw on arrival again.
    func stopTicking() { pace.withLock { ticking = false; waiting.removeAll() } }

    func redraw() {
        if let frame = lastFrame { draw(frame) }
    }

    private func draw(_ frame: VideoDecoder.Frame) {
        lock.lock() // one frame at a time (decoder thread vs. a resize redraw on main)
        defer { lock.unlock() }
        guard let cache = textureCache, let drawable = layer.nextDrawable() else { return }
        let image = frame.image
        let w = CVPixelBufferGetWidth(image), h = CVPixelBufferGetHeight(image)
        let cropRows = min(max(crop, 0), h / 2)
        var top = Float(cropRows) / Float(h) // the shown part of the texture starts here
        var luma: CVMetalTexture?, chroma: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(nil, cache, image, nil, .r8Unorm, w, h, 0, &luma)
        CVMetalTextureCacheCreateTextureFromImage(nil, cache, image, nil, .rg8Unorm, w / 2, h / 2, 1, &chroma)
        guard let luma, let chroma, let buffer = queue.makeCommandBuffer() else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        let dw = Double(drawable.texture.width), dh = Double(drawable.texture.height)
        let shownH = h - cropRows
        let scale = min(dw / Double(w), dh / Double(shownH))
        let vw = Double(w) * scale, vh = Double(shownH) * scale
        encoder.setViewport(MTLViewport(originX: (dw - vw) / 2, originY: (dh - vh) / 2, width: vw, height: vh, znear: 0, zfar: 1))
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(CVMetalTextureGetTexture(luma), index: 0)
        encoder.setFragmentTexture(CVMetalTextureGetTexture(chroma), index: 1)
        encoder.setFragmentBytes(&top, length: MemoryLayout<Float>.size, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        buffer.present(drawable)
        let pts = frame.ptsMicros
        drawable.addPresentedHandler { d in Trace.log("presented \(pts) at \(Int64(d.presentedTime * 1000))") }
        Trace.log("drawn \(pts)")
        if Trace.enabled { saveSnapshotSoon(frame, cropRows: cropRows) }
        let textures = TextureHold(luma: luma, chroma: chroma)
        buffer.addCompletedHandler { _ in _ = textures } // live until the GPU is done
        buffer.commit()
    }

    private var snapshotPending = false

    /// Trace mode: the latest frame shown, as <trace>.png, at most once a second (a blinking caret
    /// never lets the picture settle).
    private func saveSnapshotSoon(_ frame: VideoDecoder.Frame, cropRows: Int) {
        guard !snapshotPending else { return }
        snapshotPending = true
        let work = DispatchWorkItem { [self] in
            guard let path = Trace.path, let frame = lastFrame else { return }
            lock.withLock { snapshotPending = false }
            // As shown: without the cropped top rows (CIImage's origin is bottom-left).
            let full = CIImage(cvPixelBuffer: frame.image)
            let image = full.cropped(to: CGRect(x: 0, y: 0, width: full.extent.width, height: full.extent.height - CGFloat(cropRows)))
            let context = CIContext()
            try? context.writePNGRepresentation(of: image, to: URL(fileURLWithPath: path + ".png"),
                                                format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            Trace.log("snapshot \(frame.ptsMicros)")
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 1, execute: work)
    }

    /// NV12 (BT.709, limited range) → RGB. Built from source at runtime: `swift build` doesn't
    /// compile .metal files.
    private static func makePipeline(_ device: MTLDevice) -> MTLRenderPipelineState? {
        let source = """
        #include <metal_stdlib>
        using namespace metal;
        struct V { float4 position [[position]]; float2 uv; };
        vertex V vmain(uint id [[vertex_id]]) {
            float2 p = float2((id << 1) & 2, id & 2);
            V v; v.position = float4(p * 2.0 - 1.0, 0, 1); v.uv = float2(p.x, 1.0 - p.y); return v;
        }
        fragment float4 fmain(V in [[stage_in]], texture2d<float> y [[texture(0)]], texture2d<float> c [[texture(1)]],
                              constant float &top [[buffer(0)]]) {
            constexpr sampler s(filter::linear);
            float2 uv = float2(in.uv.x, top + in.uv.y * (1.0 - top));
            float Y = (y.sample(s, uv).r - 16.0 / 255.0) * (255.0 / 219.0);
            float2 C = (c.sample(s, uv).rg - 128.0 / 255.0) * (255.0 / 224.0);
            float3 rgb = float3(Y + 1.5748 * C.y, Y - 0.1873 * C.x - 0.4681 * C.y, Y + 1.8556 * C.x);
            return float4(saturate(rgb), 1);
        }
        """
        guard let library = try? device.makeLibrary(source: source, options: nil) else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "vmain")
        descriptor.fragmentFunction = library.makeFunction(name: "fmain")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        return try? device.makeRenderPipelineState(descriptor: descriptor)
    }
}

private struct TextureHold: @unchecked Sendable {
    let luma: CVMetalTexture
    let chroma: CVMetalTexture
}

/// The window's content: the renderer's layer, plus the Mac's pointer and trackpad turned into
/// touches (PointerGestures) and mouse events for the app.
final class StreamView: NSView {
    let renderer: MetalRenderer
    /// Pixel size of the video (aspect-fit into the view; also the touch mapping).
    var videoSize = CGSize(width: 9, height: 20) { didSet { gestures.size = videoRect.size } }
    weak var session: PhoneAppSession?
    private var gestures = PointerGestures(size: .zero)
    private var buttonDown = false
    private var tracking: NSTrackingArea?

    init(renderer: MetalRenderer) {
        self.renderer = renderer
        super.init(frame: .zero)
        wantsLayer = true
        layer = renderer.layer
    }

    private var displayLink: CADisplayLink?

    // MARK: Dropped files: shared to the app in the window

    var onDropFiles: (([URL]) -> Void)? {
        didSet { if onDropFiles == nil { unregisterDraggedTypes() } else { registerForDraggedTypes([.fileURL]) } }
    }

    private func droppedFiles(_ info: NSDraggingInfo) -> [URL] {
        info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        droppedFiles(sender).isEmpty ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = droppedFiles(sender)
        guard !urls.isEmpty, let onDropFiles else { return false }
        onDropFiles(urls)
        return true
    }

    /// Paces drawing to the screen this window is on (see MetalRenderer).
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        displayLink?.invalidate()
        displayLink = nil
        renderer.stopTicking()
        guard window != nil else { return }
        let link = displayLink(target: self, selector: #selector(refresh(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func refresh(_ link: CADisplayLink) { renderer.tick() }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateDrawableSize()
        gestures.size = videoRect.size
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
    }

    private func updateDrawableSize() {
        let scale = window?.backingScaleFactor ?? 2
        renderer.layer.contentsScale = scale
        renderer.layer.drawableSize = CGSize(width: max(1, bounds.width * scale), height: max(1, bounds.height * scale))
        renderer.redraw() // keep the last frame filling the window while it's resized
    }

    // MARK: - Geometry

    /// Where the video is drawn (aspect-fit, as MetalRenderer draws it), in view points.
    private var videoRect: CGRect {
        let scale = min(bounds.width / videoSize.width, bounds.height / videoSize.height)
        let vw = videoSize.width * scale, vh = videoSize.height * scale
        return CGRect(x: (bounds.width - vw) / 2, y: (bounds.height - vh) / 2, width: vw, height: vh)
    }

    /// The event's position in video points, y down.
    private func videoPoint(_ event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil), r = videoRect
        return CGPoint(x: p.x - r.minX, y: r.maxY - p.y)
    }

    private func normalised(_ p: CGPoint) -> (x: Float, y: Float) {
        let r = videoRect
        return (Float(min(max(p.x / max(r.width, 1), 0), 1)), Float(min(max(p.y / max(r.height, 1), 0), 1)))
    }

    // MARK: - Mouse

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseDown(with event: NSEvent) { button(.down, at: videoPoint(event), time: event.timestamp) }
    override func mouseDragged(with event: NSEvent) { button(.move, at: videoPoint(event), time: event.timestamp) }
    override func mouseUp(with event: NSEvent) { button(.up, at: videoPoint(event), time: event.timestamp) }

    /// The left button is a finger (pointer 0).
    func button(_ action: DisplayWire.TouchAction, at point: CGPoint, time: TimeInterval) {
        guard let session else { return }
        if action == .down {
            session.touches(gestures.cancel(), time: time) // a click ends any gesture
            buttonDown = true
        } else if !buttonDown { return }
        if action == .up { buttonDown = false }
        let n = normalised(point)
        session.touch(action, x: n.x, y: n.y, time: time)
    }

    override func rightMouseDown(with event: NSEvent) { pointer(.secondaryDown, event) }
    override func rightMouseUp(with event: NSEvent) { pointer(.secondaryUp, event) }
    override func mouseMoved(with event: NSEvent) { pointer(.hover, event) }
    override func mouseExited(with event: NSEvent) { pointer(.exit, event) }

    private func pointer(_ action: DisplayWire.MouseAction, _ event: NSEvent) {
        guard !buttonDown, !gestures.isActive || action == .exit else { return } // a finger owns the screen
        let n = normalised(videoPoint(event))
        session?.mouse(action, x: n.x, y: n.y)
    }

    // MARK: - Trackpad and wheel

    override func scrollWheel(with event: NSEvent) {
        let point = videoPoint(event)
        if event.hasPreciseScrollingDeltas, !event.phase.isEmpty || !event.momentumPhase.isEmpty {
            // A trackpad (or Magic Mouse): a finger drag; Android flings on lift by itself.
            guard event.momentumPhase.isEmpty, let phase = Self.phase(event.phase) else { return }
            scrollDrag(phase, at: point, delta: CGVector(dx: event.scrollingDeltaX, dy: event.scrollingDeltaY), time: event.timestamp)
        } else {
            // A wheel: notches (lines), or pixels from a precise wheel without phases (~40 pt a notch).
            let unit: CGFloat = event.hasPreciseScrollingDeltas ? 40 : 1
            wheel(at: point, h: Float(-event.scrollingDeltaX / unit), v: Float(event.scrollingDeltaY / unit))
        }
    }

    func scrollDrag(_ phase: PointerGestures.Phase, at point: CGPoint, delta: CGVector, time: TimeInterval) {
        guard !buttonDown else { return }
        session?.touches(gestures.scroll(phase, at: point, delta: delta), time: time)
    }

    func wheel(at point: CGPoint, h: Float, v: Float) {
        guard !buttonDown, !gestures.isActive, h != 0 || v != 0 else { return }
        let n = normalised(point)
        session?.scroll(x: n.x, y: n.y, h: h, v: v)
    }

    override func magnify(with event: NSEvent) {
        guard !buttonDown, let phase = Self.phase(event.phase) else { return }
        session?.touches(gestures.magnify(phase, at: videoPoint(event), by: event.magnification), time: event.timestamp)
    }

    override func rotate(with event: NSEvent) {
        guard !buttonDown, let phase = Self.phase(event.phase) else { return }
        session?.touches(gestures.rotate(phase, at: videoPoint(event), by: CGFloat(event.rotation)), time: event.timestamp)
    }

    func pinch(_ phase: PointerGestures.Phase, at point: CGPoint, by magnification: CGFloat, time: TimeInterval) {
        session?.touches(gestures.magnify(phase, at: point, by: magnification), time: time)
    }

    /// Lifts everything (the window stopped being key mid-gesture).
    func cancelInput() {
        guard let session else { return }
        let time = ProcessInfo.processInfo.systemUptime
        session.touches(gestures.cancel(), time: time)
        if buttonDown { buttonDown = false; session.touch(.cancel, x: 0, y: 0, time: time) }
    }

    private static func phase(_ p: NSEvent.Phase) -> PointerGestures.Phase? {
        if p.contains(.began) { return .began }
        if p.contains(.changed) { return .changed }
        if p.contains(.ended) || p.contains(.cancelled) { return .ended }
        return nil // mayBegin, stationary
    }

    /// The video's size in points (for test hooks working in video points).
    var videoPointSize: CGSize { videoRect.size }

    // MARK: - Keyboard

    /// Dead-key / input-method composition in progress (the Mac shows its own candidate UI).
    private var marked = ""

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // ⌘ shortcuts reach views before the menus: the phone's, except the Mac's own (⌘W, ⌘Q…).
        guard event.type == .keyDown, window?.firstResponder === self, event.modifierFlags.contains(.command) else {
            return super.performKeyEquivalent(with: event)
        }
        if let c = event.charactersIgnoringModifiers, macShortcuts.contains(c),
           event.modifierFlags.isDisjoint(with: [.control, .option]) {
            return super.performKeyEquivalent(with: event) // the window's own (phone window: ⌘1, ⌘2, ⌘+…)
        }
        let action = keyAction(event)
        if action == .mac { return super.performKeyEquivalent(with: event) }
        perform(action, event)
        return true
    }

    /// ⌘ keys (by character) the window's menus handle instead of the phone.
    var macShortcuts: Set<String> = []

    override func keyDown(with event: NSEvent) {
        let action = hasMarkedText() ? .text : keyAction(event) // composing: the input method owns the keys
        perform(action, event)
    }

    private func keyAction(_ event: NSEvent) -> KeyMap.Action {
        var m: KeyMap.Modifiers = []
        let flags = event.modifierFlags
        if flags.contains(.shift) { m.insert(.shift) }
        if flags.contains(.control) { m.insert(.control) }
        if flags.contains(.option) { m.insert(.option) }
        if flags.contains(.command) { m.insert(.command) }
        return KeyMap.action(keyCode: event.keyCode, modifiers: m, characters: event.charactersIgnoringModifiers)
    }

    private func perform(_ action: KeyMap.Action, _ event: NSEvent) {
        switch action {
        case .text: interpretKeyEvents([event])
        case .keys(let keys): session?.keys(keys)
        case .paste: session?.paste(NSPasteboard.general.string(forType: .string))
        case .back: session?.back()
        case .mac: super.keyDown(with: event)
        case .none: break
        }
    }

    /// Lets the test hook type as if from the keyboard.
    func typeForTesting(_ text: String) { insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0)) }
}

extension StreamView: @preconcurrency NSTextInputClient {
    func insertText(_ string: Any, replacementRange: NSRange) {
        marked = ""
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        if !text.isEmpty { session?.text(text) }
    }

    /// Keys that aren't text were handled before the text system saw them; nothing else to do.
    override func doCommand(by selector: Selector) {}

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        marked = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
    }

    func unmarkText() { marked = "" }
    func hasMarkedText() -> Bool { !marked.isEmpty }
    func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }

    func markedRange() -> NSRange {
        marked.isEmpty ? NSRange(location: NSNotFound, length: 0) : NSRange(location: 0, length: (marked as NSString).length)
    }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func characterIndex(for point: NSPoint) -> Int { NSNotFound }

    /// Where an input method puts its candidates: we can't know the phone's caret, so low in the
    /// window, where keyboards and text fields usually are.
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        let r = videoRect
        let rect = NSRect(x: r.minX + 24, y: r.minY + r.height * 0.3, width: 1, height: 20)
        return window?.convertToScreen(convert(rect, to: nil)) ?? .zero
    }
}
