import AppKit
import CoreMediaIO
import NearsideCore
import SystemExtensions
import VideoToolbox

/// The phone's camera as a Mac webcam: "Nearside Camera", a camera extension inside the app.
/// - Turning it on in Settings activates the extension (macOS asks you to allow it once).
/// - While an app (FaceTime, Zoom, a browser) uses Nearside Camera, the extension says so; we
///   then open the phone's camera and feed its picture into the extension's sink stream. When the
///   last app stops, the phone's camera turns off.
@MainActor @Observable
final class Webcam: NSObject {
    static let extensionID = "dev.nearside.mac.camera"
    /// Made at launch (StatusItemController); Settings shows it.
    private(set) static var shared: Webcam?
    /// This build has the camera extension (signed builds with the provisioning profiles).
    static var available: Bool {
        FileManager.default.fileExists(atPath: Bundle.main.bundlePath + "/Contents/Library/SystemExtensions/\(extensionID).systemextension")
    }

    static func start(engine: SyncEngine) { if shared == nil { shared = Webcam(engine: engine) } }
    /// Must match the extension's device id (Sources/NearsideCamera/main.swift).
    private static let deviceUID = "6E2A2B0C-4C1D-4B8E-9D55-6E6561727369"
    static let enabledKey = "Webcam.enabled"
    static let frontKey = "Webcam.front"

    /// What Settings shows about the extension.
    private(set) var status = ""
    private(set) var inUse = false

    @ObservationIgnored private let engine: SyncEngine
    @ObservationIgnored private var poll: Timer?
    @ObservationIgnored private var device: CMIOObjectID = 0
    @ObservationIgnored private var sink: CMIOStreamID = 0
    @ObservationIgnored private var session: CameraSession?
    @ObservationIgnored private var feeder: SinkFeeder?

    init(engine: SyncEngine) {
        self.engine = engine
        super.init()
        if UserDefaults.standard.bool(forKey: Self.enabledKey) { watch(true) }
    }

    var enabled: Bool {
        get { access(keyPath: \.status); return UserDefaults.standard.bool(forKey: Self.enabledKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.enabledKey)
            let request = newValue
                ? OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: Self.extensionID, queue: .main)
                : OSSystemExtensionRequest.deactivationRequest(forExtensionWithIdentifier: Self.extensionID, queue: .main)
            request.delegate = self
            OSSystemExtensionManager.shared.submitRequest(request)
            status = newValue ? "Turning on…" : "Turning off…"
            watch(newValue)
        }
    }

    // MARK: Watching for apps using the camera

    private func watch(_ on: Bool) {
        poll?.invalidate()
        poll = nil
        if !on { stopFeeding(); return }
        poll = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
    }

    private func check() {
        if device == 0 { device = Self.findDevice() }
        guard device != 0 else { return }
        let used = Self.readInUse(device)
        if used != inUse { inUse = used }
        if used, session == nil, engine.state == .connected { startFeeding() }
        if !used, session != nil { stopFeeding() }
    }

    private func startFeeding() {
        guard let (stream, queue) = Self.openSink(device) else {
            status = "Couldn't reach Nearside Camera."
            return
        }
        sink = stream
        let feeder = SinkFeeder(queue: queue)
        self.feeder = feeder
        let camera = engine.makeCameraSession(front: UserDefaults.standard.bool(forKey: Self.frontKey))
        camera.onFrame = { frame in feeder.push(frame.image) }
        camera.onEnded = { [weak self] in
            Task { @MainActor in
                // The phone went (or its camera couldn't open): try again on the next check.
                guard let self, self.session === camera else { return }
                self.stopFeeding()
            }
        }
        session = camera
        camera.start()
        NSLog("Nearside: webcam: an app is using Nearside Camera; phone camera on")
    }

    private func stopFeeding() {
        guard session != nil || sink != 0 else { return }
        session?.onEnded = nil
        session?.stop()
        session = nil
        if sink != 0 { CMIODeviceStopStream(device, sink) }
        sink = 0
        feeder = nil
        NSLog("Nearside: webcam: phone camera off")
    }

    // MARK: Core Media I/O

    private static func address(_ selector: Int, scope: Int = kCMIOObjectPropertyScopeGlobal) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(selector), mScope: CMIOObjectPropertyScope(scope),
                                  mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    }

    private static func ids(_ object: CMIOObjectID, _ selector: Int) -> [CMIOObjectID] {
        var address = address(selector)
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(object, &address, 0, nil, &size) == 0, size > 0 else { return [] }
        var list = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(object, &address, 0, nil, size, &used, &list) == 0 else { return [] }
        return list
    }

    private static func string(_ object: CMIOObjectID, _ selector: Int) -> String? {
        var address = address(selector)
        var value: Unmanaged<CFString>?
        var used: UInt32 = 0
        let size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard CMIOObjectGetPropertyData(object, &address, 0, nil, size, &used, &value) == 0 else { return nil }
        return value?.takeRetainedValue() as String?
    }

    private static func findDevice() -> CMIOObjectID {
        ids(CMIOObjectID(kCMIOObjectSystemObject), kCMIOHardwarePropertyDevices)
            .first { string($0, kCMIODevicePropertyDeviceUID) == deviceUID } ?? 0
    }

    /// The extension's "nuse" property: "1" while an app uses the camera.
    private static func readInUse(_ device: CMIOObjectID) -> Bool {
        string(device, Int(fourCC("nuse"))) == "1"
    }

    private static func fourCC(_ s: String) -> UInt32 { s.utf8.reduce(0) { $0 << 8 | UInt32($1) } }

    /// The sink stream (the one that takes input), started, with its queue.
    private static func openSink(_ device: CMIOObjectID) -> (CMIOStreamID, CMSimpleQueue)? {
        for stream in ids(device, kCMIODevicePropertyStreams) {
            var address = address(kCMIOStreamPropertyDirection)
            var direction: UInt32 = 0
            var used: UInt32 = 0
            guard CMIOObjectGetPropertyData(stream, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &used, &direction) == 0,
                  direction == 1 else { continue }
            var queue: Unmanaged<CMSimpleQueue>?
            guard CMIOStreamCopyBufferQueue(stream, { _, _, _ in }, nil, &queue) == 0, let queue else { continue }
            guard CMIODeviceStartStream(device, stream) == 0 else { continue }
            return (stream, queue.takeRetainedValue())
        }
        return nil
    }
}

extension Webcam: OSSystemExtensionRequestDelegate {
    nonisolated func request(_ request: OSSystemExtensionRequest,
                             actionForReplacingExtension existing: OSSystemExtensionProperties,
                             withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        .replace // a newer Nearside brings a newer camera
    }

    nonisolated func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        Task { @MainActor in
            status = "Allow it in System Settings › General › Login Items & Extensions › Camera Extensions."
        }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        Task { @MainActor in
            status = enabled ? "On. Pick “Nearside Camera” in any app." : "Off."
        }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        let text = (error as NSError).code == OSSystemExtensionError.unsupportedParentBundleLocation.rawValue
            ? "Move Nearside to the Applications folder first." : error.localizedDescription
        Task { @MainActor in status = text }
    }
}

/// Phone frames, scaled to the camera's format, into the extension's sink queue (any thread).
private final class SinkFeeder: @unchecked Sendable {
    private let queue: CMSimpleQueue
    private let lock = NSLock()
    private var transfer: VTPixelTransferSession?
    private var pool: CVPixelBufferPool?
    private var format: CMFormatDescription?

    init(queue: CMSimpleQueue) {
        self.queue = queue
        VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &transfer)
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey: 1920, kCVPixelBufferHeightKey: 1080,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool)
    }

    func push(_ image: CVPixelBuffer) {
        lock.lock()
        defer { lock.unlock() }
        // The extension holds one frame: a full queue means it hasn't taken the last yet; skip.
        guard CMSimpleQueueGetCount(queue) < CMSimpleQueueGetCapacity(queue),
              let transfer, let pool else { return }
        var out: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &out)
        guard let out, VTPixelTransferSessionTransferImage(transfer, from: image, to: out) == noErr else { return }
        if format == nil { CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: out, formatDescriptionOut: &format) }
        guard let format else { return }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
                                        presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: out, dataReady: true,
                                           makeDataReadyCallback: nil, refcon: nil, formatDescription: format,
                                           sampleTiming: &timing, sampleBufferOut: &sample)
        guard let sample else { return }
        CMSimpleQueueEnqueue(queue, element: Unmanaged.passRetained(sample).toOpaque())
    }
}
