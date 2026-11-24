import AppKit
import AVFoundation
import CoreMediaIO
import os
import NearsideCore
import SystemExtensions
import VideoToolbox

/// The phone's camera as a Mac webcam: "Nearside Camera", a camera extension inside the app.
/// - Turning it on in Settings activates the extension (macOS asks you to allow it once).
/// - While an app (FaceTime, Zoom, a browser) uses Nearside Camera, the extension says so; we
///   then open the phone's camera and feed its picture into the extension's sink stream. When the
///   last app stops, the phone's camera turns off.
private let log = Logger(subsystem: "dev.nearside.mac", category: "webcam")

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
    @ObservationIgnored private var checks = 0
    @ObservationIgnored private var device: CMIOObjectID = 0
    @ObservationIgnored private var sink: CMIOStreamID = 0
    @ObservationIgnored private var session: CameraSession?
    @ObservationIgnored private var feeder: SinkFeeder?
    /// The phone's Stop: no camera until the app using Nearside Camera stops and starts it again.
    @ObservationIgnored private var stoppedOnPhone = false
    /// After the stream failed (not stopped by us): the next try waits until then.
    @ObservationIgnored private var retryAfter = Date.distantPast
    /// When the current session started, and whether a picture has come since.
    @ObservationIgnored private var startedAt = Date.distantPast
    @ObservationIgnored private let frames = FrameCount()

    /// The phone's "Stop" on its in-use notification.
    func phoneStopped() {
        stoppedOnPhone = true
        stopFeeding()
    }

    init(engine: SyncEngine) {
        self.engine = engine
        super.init()
        if UserDefaults.standard.bool(forKey: Self.enabledKey) {
            // Every launch, as Apple recommends: an updated Nearside brings its updated camera
            // (the delegate replaces the old one); one already current is a no-op.
            let request = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: Self.extensionID, queue: .main)
            request.delegate = self
            OSSystemExtensionManager.shared.submitRequest(request)
            askForCamera()
            watch(true)
        }
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
            if newValue { askForCamera() }
            watch(newValue)
        }
    }

    /// macOS hides every camera, Nearside Camera too, from an app without camera access: without
    /// it we can't find the camera to feed. (We never read the Mac's own camera.)
    private func askForCamera() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                log.notice("camera access \(granted ? "granted" : "denied", privacy: .public)")
            }
        case .denied, .restricted:
            status = "Allow Nearside in System Settings › Privacy & Security › Camera (it only uses it to find Nearside Camera)."
        default:
            break
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
        if device == 0 {
            device = Self.findDevice()
            if device != 0 {
                log.notice("found Nearside Camera")
                // Subscribing is what keeps these fresh in this process: without listeners Core
                // Media I/O kept answering "nuse" with the value from launch.
                Self.listen(device, Int(Self.fourCC("nuse")))
                Self.listen(device, kCMIODevicePropertyDeviceIsRunningSomewhere)
            }
        }
        checks += 1
        guard device != 0 else {
            if checks % 15 == 1 {
                let all = Self.ids(CMIOObjectID(kCMIOObjectSystemObject), kCMIOHardwarePropertyDevices)
                log.notice("Nearside Camera not found among \(all.count, privacy: .public) cameras: \(all.map { Self.string($0, kCMIODevicePropertyDeviceUID) ?? "?" }, privacy: .public)")
            }
            return
        }
        // The extension's flag, or (before we feed it, when only apps can be running it) macOS's
        // own "running somewhere".
        let used = Self.readInUse(device) || (session == nil && Self.runningSomewhere(device))
        if used != inUse {
            inUse = used
            log.notice("Nearside Camera \(used ? "in use" : "not in use", privacy: .public)")
        }
        if !used { stoppedOnPhone = false } // the app let go: the next start is a new one
        // Started but no picture in 10 s (the phone never answered): drop it and try again.
        if session != nil, frames.value == 0, Date().timeIntervalSince(startedAt) > 10 {
            log.error("no picture from the phone in 10 s; trying again")
            stopFeeding()
        }
        if used, session == nil, !stoppedOnPhone, Date() >= retryAfter {
            if engine.state == .connected { startFeeding() } else { log.notice("waiting for the phone to connect") ; retryAfter = Date().addingTimeInterval(5) }
        }
        if !used, session != nil { stopFeeding() }
    }

    private func startFeeding() {
        guard let (stream, queue) = Self.openSink(device) else {
            status = "Couldn't reach Nearside Camera."
            log.error("couldn't open the camera's input stream")
            return
        }
        sink = stream
        let feeder = SinkFeeder(queue: queue)
        self.feeder = feeder
        let camera = engine.makeCameraSession(front: UserDefaults.standard.bool(forKey: Self.frontKey))
        let frames = frames
        frames.reset()
        startedAt = Date()
        camera.onFrame = { frame in
            if frames.increment() == 1 { log.notice("first picture from the phone") }
            feeder.push(frame.image)
        }
        camera.onEnded = { [weak self] in
            Task { @MainActor in
                // The phone went (or its camera couldn't open): try again in a few seconds.
                guard let self, self.session === camera else { return }
                log.error("the phone's camera stream ended")
                self.stopFeeding()
                self.retryAfter = Date().addingTimeInterval(5)
            }
        }
        session = camera
        camera.start()
        log.notice("an app is using Nearside Camera; phone camera on")
    }

    private func stopFeeding() {
        guard session != nil || sink != 0 else { return }
        session?.onEnded = nil
        session?.stop()
        session = nil
        if sink != 0 { CMIODeviceStopStream(device, sink) }
        sink = 0
        feeder = nil
        log.notice("phone camera off")
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

    private static func runningSomewhere(_ device: CMIOObjectID) -> Bool {
        var address = address(kCMIODevicePropertyDeviceIsRunningSomewhere)
        var value: UInt32 = 0
        var used: UInt32 = 0
        return CMIOObjectGetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &used, &value) == 0 && value != 0
    }

    /// A no-op listener: its existence makes Core Media I/O track the property for this process.
    private static func listen(_ device: CMIOObjectID, _ selector: Int) {
        var address = address(selector)
        let status = CMIOObjectAddPropertyListenerBlock(device, &address, DispatchQueue.main) { _, _ in }
        if status != 0 { log.error("listening to \(selector, privacy: .public) failed: \(status, privacy: .public)") }
    }

    /// Proves to the extension that the writer is us: a fresh random key in the app group's
    /// container (only Nearside and the extension can open it), presented on the stream.
    private static func presentKey(on stream: CMIOStreamID) -> Bool {
        guard let dir = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "X97D6QH7RS.dev.nearside.mac") else {
            log.error("no app group container")
            return false
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return false }
        let key = bytes.map { String(format: "%02x", $0) }.joined()
        let file = dir.appendingPathComponent("sink-key")
        guard FileManager.default.createFile(atPath: file.path, contents: Data(key.utf8), attributes: [.posixPermissions: 0o600]) else {
            log.error("couldn't write the camera key")
            return false
        }
        var address = address(Int(fourCC("skey")))
        var value: CFString = key as CFString
        let status = CMIOObjectSetPropertyData(stream, &address, 0, nil, UInt32(MemoryLayout<CFString>.size), &value)
        if status != 0 { log.error("presenting the camera key failed: \(status, privacy: .public)") }
        return status == 0
    }

    /// The sink stream (the one that takes our frames), started, with its queue.
    private static func openSink(_ device: CMIOObjectID) -> (CMIOStreamID, CMSimpleQueue)? {
        for stream in ids(device, kCMIODevicePropertyStreams) {
            // By name (the extension's SinkSource): which "direction" a sink reports is murky.
            guard string(stream, kCMIOObjectPropertyName) == "Nearside Camera Input" else { continue }
            guard presentKey(on: stream) else { continue }
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

/// Pictures received in the current session (any thread).
private final class FrameCount: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    var value: Int { lock.withLock { n } }
    func reset() { lock.withLock { n = 0 } }
    func increment() -> Int { lock.withLock { n += 1; return n } }
}
