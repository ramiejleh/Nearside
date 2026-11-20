import NearsideCore
import AppKit
import CoreImage
import CoreVideo
import Metal
import QuartzCore

/// Draws a phone app's frames with Metal, from any thread.
///
/// Frames are drawn the moment they're decoded (no display link, vsync off for this layer):
/// Gate B measured that at ~31 ms capture→screen against ~77 ms when waiting on a
/// CAMetalDisplayLink. In a window WindowServer composites anyway, so there's no tearing.
final class MetalRenderer: @unchecked Sendable {
    let layer = CAMetalLayer()
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private var textureCache: CVMetalTextureCache?
    private let lock = NSLock()
    private var latest: VideoDecoder.Frame?

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
              let pipeline = Self.makePipeline(device) else { return nil }
        self.queue = queue
        self.pipeline = pipeline
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
        layer.displaySyncEnabled = false
        layer.maximumDrawableCount = 2
        layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        layer.backgroundColor = CGColor(gray: 0, alpha: 1)
        CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)
    }

    /// The newest frame, if any.
    var lastFrame: VideoDecoder.Frame? { lock.withLock { latest } }

    func show(_ frame: VideoDecoder.Frame) {
        lock.withLock { latest = frame }
        draw(frame)
    }

    func redraw() {
        if let frame = lastFrame { draw(frame) }
    }

    private func draw(_ frame: VideoDecoder.Frame) {
        lock.lock() // one frame at a time (decoder thread vs. a resize redraw on main)
        defer { lock.unlock() }
        guard let cache = textureCache, let drawable = layer.nextDrawable() else { return }
        let image = frame.image
        let w = CVPixelBufferGetWidth(image), h = CVPixelBufferGetHeight(image)
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
        let scale = min(dw / Double(w), dh / Double(h))
        let vw = Double(w) * scale, vh = Double(h) * scale
        encoder.setViewport(MTLViewport(originX: (dw - vw) / 2, originY: (dh - vh) / 2, width: vw, height: vh, znear: 0, zfar: 1))
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(CVMetalTextureGetTexture(luma), index: 0)
        encoder.setFragmentTexture(CVMetalTextureGetTexture(chroma), index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        buffer.present(drawable)
        let pts = frame.ptsMicros
        drawable.addPresentedHandler { d in Trace.log("presented \(pts) at \(Int64(d.presentedTime * 1000))") }
        Trace.log("drawn \(pts)")
        if Trace.enabled { saveSnapshotSoon(frame) }
        let textures = TextureHold(luma: luma, chroma: chroma)
        buffer.addCompletedHandler { _ in _ = textures } // live until the GPU is done
        buffer.commit()
    }

    private var snapshotWork: DispatchWorkItem?

    /// Trace mode: the last frame shown, as <trace>.png, a second after the picture settles.
    private func saveSnapshotSoon(_ frame: VideoDecoder.Frame) {
        snapshotWork?.cancel()
        let work = DispatchWorkItem {
            guard let path = Trace.path else { return }
            let image = CIImage(cvPixelBuffer: frame.image)
            let context = CIContext()
            try? context.writePNGRepresentation(of: image, to: URL(fileURLWithPath: path + ".png"),
                                                format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            Trace.log("snapshot \(frame.ptsMicros)")
        }
        snapshotWork = work
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
        fragment float4 fmain(V in [[stage_in]], texture2d<float> y [[texture(0)]], texture2d<float> c [[texture(1)]]) {
            constexpr sampler s(filter::linear);
            float Y = (y.sample(s, in.uv).r - 16.0 / 255.0) * (255.0 / 219.0);
            float2 C = (c.sample(s, in.uv).rg - 128.0 / 255.0) * (255.0 / 224.0);
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
}
