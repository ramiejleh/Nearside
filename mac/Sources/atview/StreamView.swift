import AppKit
import CoreVideo
import Metal
import QuartzCore

/// Shows decoded frames with Metal: a CAMetalLayer driven by CAMetalDisplayLink, drawing only the
/// newest frame (older undrawn ones are dropped). NV12 → RGB (BT.709 limited range) in a shader.
final class StreamView: NSView, CAMetalDisplayLinkDelegate {
    private let device = MTLCreateSystemDefaultDevice()!
    private lazy var queue = device.makeCommandQueue()!
    private let metalLayer = CAMetalLayer()
    private var pipeline: MTLRenderPipelineState!
    private var textureCache: CVMetalTextureCache!
    private var displayLink: CAMetalDisplayLink?

    private let lock = NSLock()
    private var pending: VideoDecoder.Frame?
    private var current: VideoDecoder.Frame?
    /// Frames replaced before they could be drawn.
    private(set) var dropped = 0
    var onPresented: ((VideoDecoder.Frame, Int64) -> Void)?
    /// Touch callback: action (0 down, 1 up, 2 move), normalised x/y in the video.
    var onTouch: ((Int, Float, Float) -> Void)?
    var videoSize = CGSize(width: 9, height: 16)
    /// ATVIEW_MODE=immediate: draw as soon as a frame is decoded, no vsync (latency experiment).
    let immediate = ProcessInfo.processInfo.environment["ATVIEW_MODE"] == "immediate"
    /// decoded → drawn (command buffer committed), for the stage breakdown.
    var onDrawn: ((VideoDecoder.Frame, Int64) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        metalLayer.device = device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        layer = metalLayer
        CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)
        buildPipeline()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, displayLink == nil else { return }
        print("screen max fps \(window!.screen?.maximumFramesPerSecond ?? 0), immediate=\(immediate)")
        if immediate {
            metalLayer.displaySyncEnabled = false
            metalLayer.maximumDrawableCount = 2
            updateDrawableSize()
            return
        }
        let link = CAMetalDisplayLink(metalLayer: metalLayer)
        link.delegate = self
        link.preferredFrameLatency = 1
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        displayLink = link
        updateDrawableSize()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateDrawableSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
    }

    private func updateDrawableSize() {
        let scale = window?.backingScaleFactor ?? 2
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(width: max(1, bounds.width * scale), height: max(1, bounds.height * scale))
    }

    /// Called from the decoder's thread.
    func enqueue(_ frame: VideoDecoder.Frame) {
        if immediate {
            lock.withLock { current = frame }
            if let drawable = metalLayer.nextDrawable() { draw(frame, to: drawable, isNew: true) }
            return
        }
        lock.withLock {
            if pending != nil { dropped += 1 }
            pending = frame
        }
    }

    func metalDisplayLink(_ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update) {
        let next = lock.withLock { () -> VideoDecoder.Frame? in
            defer { pending = nil }
            return pending
        }
        // Redraw on a new frame, and while live-resizing (the last frame scales to the window).
        guard let frame = next ?? (inLiveResize ? current : nil) else { return }
        current = frame
        draw(frame, to: update.drawable, isNew: next != nil)
    }

    private func draw(_ frame: VideoDecoder.Frame, to drawable: CAMetalDrawable, isNew: Bool) {
        let image = frame.image
        let w = CVPixelBufferGetWidth(image), h = CVPixelBufferGetHeight(image)
        guard let luma = texture(image, plane: 0, format: .r8Unorm, w, h),
              let chroma = texture(image, plane: 1, format: .rg8Unorm, w / 2, h / 2),
              let buffer = queue.makeCommandBuffer() else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        // Aspect-fit the video into the drawable.
        let dw = Double(drawable.texture.width), dh = Double(drawable.texture.height)
        let scale = min(dw / Double(w), dh / Double(h))
        let vw = Double(w) * scale, vh = Double(h) * scale
        encoder.setViewport(MTLViewport(originX: (dw - vw) / 2, originY: (dh - vh) / 2,
                                        width: vw, height: vh, znear: 0, zfar: 1))
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(CVMetalTextureGetTexture(luma), index: 0)
        encoder.setFragmentTexture(CVMetalTextureGetTexture(chroma), index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        if isNew {
            drawable.addPresentedHandler { [weak self] presented in
                guard presented.presentedTime > 0 else { return }
                self?.onPresented?(frame, Int64(presented.presentedTime * 1_000_000))
            }
        }
        buffer.present(drawable)
        if isNew { onDrawn?(frame, macMicros()) }
        buffer.addCompletedHandler { _ in _ = (luma, chroma) } // keep textures alive until done
        buffer.commit()
    }

    private func texture(_ image: CVPixelBuffer, plane: Int, format: MTLPixelFormat, _ w: Int, _ h: Int) -> CVMetalTexture? {
        var texture: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(nil, textureCache, image, nil, format, w, h, plane, &texture)
        return texture
    }

    private func buildPipeline() {
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
            float Y = (y.sample(s, in.uv).r - 16.0/255.0) * (255.0/219.0);
            float2 C = (c.sample(s, in.uv).rg - 128.0/255.0) * (255.0/224.0);
            float3 rgb = float3(Y + 1.5748 * C.y, Y - 0.1873 * C.x - 0.4681 * C.y, Y + 1.8556 * C.x);
            return float4(saturate(rgb), 1);
        }
        """
        let library = try! device.makeLibrary(source: source, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "vmain")
        descriptor.fragmentFunction = library.makeFunction(name: "fmain")
        descriptor.colorAttachments[0].pixelFormat = metalLayer.pixelFormat
        pipeline = try! device.makeRenderPipelineState(descriptor: descriptor)
    }

    // MARK: - Mouse → touch

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { touch(0, event) }
    override func mouseDragged(with event: NSEvent) { touch(2, event) }
    override func mouseUp(with event: NSEvent) { touch(1, event) }

    private func touch(_ action: Int, _ event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let scale = min(bounds.width / videoSize.width, bounds.height / videoSize.height)
        let vw = videoSize.width * scale, vh = videoSize.height * scale
        let x = (p.x - (bounds.width - vw) / 2) / vw
        let y = 1 - (p.y - (bounds.height - vh) / 2) / vh
        onTouch?(action, Float(min(max(x, 0), 1)), Float(min(max(y, 0), 1)))
    }
}
