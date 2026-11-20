import NearsideCore
import AppKit
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
        let textures = TextureHold(luma: luma, chroma: chroma)
        buffer.addCompletedHandler { _ in _ = textures } // live until the GPU is done
        buffer.commit()
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

/// The window's content: the renderer's layer, plus mouse → touch.
final class StreamView: NSView {
    let renderer: MetalRenderer
    /// Pixel size of the video (aspect-fit into the view; also the touch mapping).
    var videoSize = CGSize(width: 9, height: 20)
    var onTouch: ((DisplayWire.TouchAction, Float, Float) -> Void)?

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

    // MARK: - Mouse → touch (keyboard, scroll and gestures come in the input milestone)

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { touch(.down, event) }
    override func mouseDragged(with event: NSEvent) { touch(.move, event) }
    override func mouseUp(with event: NSEvent) { touch(.up, event) }

    private func touch(_ action: DisplayWire.TouchAction, _ event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let scale = min(bounds.width / videoSize.width, bounds.height / videoSize.height)
        let vw = videoSize.width * scale, vh = videoSize.height * scale
        let x = (p.x - (bounds.width - vw) / 2) / vw
        let y = 1 - (p.y - (bounds.height - vh) / 2) / vh
        onTouch?(action, Float(min(max(x, 0), 1)), Float(min(max(y, 0), 1)))
    }
}
