// Nearside Camera: a Core Media I/O camera extension (a system extension inside Nearside.app).
// Apps (FaceTime, Zoom, browsers) see one camera, "Nearside Camera". Nearside itself feeds it the
// phone's camera through a sink stream, and only while an app is using it: the extension
// publishes that as a custom property ("nuse") that Nearside watches. The extension is sandboxed
// and has no network or adb of its own.

import CoreMediaIO
import Foundation
import os

let log = Logger(subsystem: "dev.nearside.mac.camera", category: "camera")

enum Camera {
    static let width: Int32 = 1920
    static let height: Int32 = 1080
    static let fps: Int32 = 30
    static let pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    /// Fixed, so apps remember the camera across launches.
    static let deviceID = UUID(uuidString: "6E2A2B0C-4C1D-4B8E-9D55-6E6561727369")!
    static let sourceID = UUID(uuidString: "6E2A2B0C-4C1D-4B8E-9D55-736F75726365")!
    static let sinkID = UUID(uuidString: "6E2A2B0C-4C1D-4B8E-9D55-73696E6B0000")!
    /// "An app is using the camera": "1" or "0" (read by Nearside).
    static let inUse = CMIOExtensionProperty(rawValue: "4cc_nuse_glob_0000")
    /// The sink's key, presented by its writer (see SinkSource).
    static let sinkKey = CMIOExtensionProperty(rawValue: "4cc_skey_glob_0000")
    static let group = "X97D6QH7RS.dev.nearside.mac"
}

final class DeviceSource: NSObject, CMIOExtensionDeviceSource, @unchecked Sendable {
    private(set) var device: CMIOExtensionDevice!
    private var source: StreamSource!
    private var sink: SinkSource!
    private let format: CMFormatDescription
    private let queue = DispatchQueue(label: "nearside.camera")
    private var clients = 0
    private var lastFrame = Date.distantPast
    private var placeholderTimer: DispatchSourceTimer?
    private var placeholder: CVPixelBuffer?

    override init() {
        var description: CMFormatDescription?
        CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault, codecType: Camera.pixelFormat,
                                       width: Camera.width, height: Camera.height, extensions: nil, formatDescriptionOut: &description)
        format = description!
        super.init()
        device = CMIOExtensionDevice(localizedName: "Nearside Camera", deviceID: Camera.deviceID, legacyDeviceID: nil, source: self)
        let duration = CMTime(value: 1, timescale: Camera.fps)
        let streamFormat = CMIOExtensionStreamFormat(formatDescription: format, maxFrameDuration: duration,
                                                     minFrameDuration: duration, validFrameDurations: nil)
        source = StreamSource(streamFormat, device: self)
        sink = SinkSource(streamFormat, device: self)
        do {
            try device.addStream(source.stream)
            try device.addStream(sink.stream)
        } catch {
            log.error("adding streams failed: \(error.localizedDescription)")
        }
    }

    var availableProperties: Set<CMIOExtensionProperty> { [.deviceTransportType, .deviceModel, Camera.inUse] }

    func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionDeviceProperties {
        let p = CMIOExtensionDeviceProperties(dictionary: [:])
        if properties.contains(.deviceTransportType) { p.transportType = 0x7669_7274 } // 'virt'
        if properties.contains(.deviceModel) { p.model = "Nearside Camera" }
        if properties.contains(Camera.inUse) {
            p.setPropertyState(CMIOExtensionPropertyState(value: (clients > 0 ? "1" : "0") as NSString), forProperty: Camera.inUse)
        }
        return p
    }

    func setDeviceProperties(_ deviceProperties: CMIOExtensionDeviceProperties) throws {}

    // MARK: Apps using the camera

    func sourceStarted() {
        queue.async { [self] in
            clients += 1
            log.info("an app started the camera")
            announce()
            startPlaceholder()
        }
    }

    func sourceStopped() {
        queue.async { [self] in
            clients = max(0, clients - 1)
            log.info("an app stopped the camera")
            announce()
            if clients == 0 { placeholderTimer?.cancel(); placeholderTimer = nil }
        }
    }

    private func announce() {
        device.notifyPropertiesChanged([Camera.inUse: CMIOExtensionPropertyState<AnyObject>(value: (clients > 0 ? "1" : "0") as NSString)])
    }

    // MARK: Frames

    /// A frame from Nearside (the sink): on to the apps.
    func forward(_ buffer: CMSampleBuffer) {
        queue.async { [self] in
            guard clients > 0 else { return }
            lastFrame = Date()
            source.stream.send(buffer, discontinuity: [], hostTimeInNanoseconds: Self.now())
        }
    }

    /// Black while the phone's picture isn't there (its camera takes a moment to start).
    private func startPlaceholder() {
        guard placeholderTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(1000 / Int(Camera.fps)))
        timer.setEventHandler { [weak self] in
            guard let self, Date().timeIntervalSince(lastFrame) > 0.5, let buffer = blackFrame() else { return }
            source.stream.send(buffer, discontinuity: [], hostTimeInNanoseconds: Self.now())
        }
        timer.resume()
        placeholderTimer = timer
    }

    private func blackFrame() -> CMSampleBuffer? {
        if placeholder == nil {
            var pixels: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault, Int(Camera.width), Int(Camera.height), Camera.pixelFormat,
                                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixels)
            guard let pixels else { return nil }
            CVPixelBufferLockBaseAddress(pixels, [])
            // Video range: luma 16 is black, chroma 128 is no colour.
            if let y = CVPixelBufferGetBaseAddressOfPlane(pixels, 0) {
                memset(y, 16, CVPixelBufferGetBytesPerRowOfPlane(pixels, 0) * CVPixelBufferGetHeightOfPlane(pixels, 0))
            }
            if let uv = CVPixelBufferGetBaseAddressOfPlane(pixels, 1) {
                memset(uv, 128, CVPixelBufferGetBytesPerRowOfPlane(pixels, 1) * CVPixelBufferGetHeightOfPlane(pixels, 1))
            }
            CVPixelBufferUnlockBaseAddress(pixels, [])
            placeholder = pixels
        }
        guard let pixels = placeholder else { return nil }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: Camera.fps),
                                        presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixels, dataReady: true,
                                           makeDataReadyCallback: nil, refcon: nil, formatDescription: format,
                                           sampleTiming: &timing, sampleBufferOut: &sample)
        return sample
    }

    static func now() -> UInt64 { UInt64(CMClockGetTime(CMClockGetHostTimeClock()).seconds * 1_000_000_000) }
}

/// What apps read.
final class StreamSource: NSObject, CMIOExtensionStreamSource, @unchecked Sendable {
    private(set) var stream: CMIOExtensionStream!
    private let format: CMIOExtensionStreamFormat
    private unowned let device: DeviceSource

    init(_ format: CMIOExtensionStreamFormat, device: DeviceSource) {
        self.format = format
        self.device = device
        super.init()
        stream = CMIOExtensionStream(localizedName: "Nearside Camera", streamID: Camera.sourceID, direction: .source,
                                     clockType: .hostTime, source: self)
    }

    var formats: [CMIOExtensionStreamFormat] { [format] }
    var availableProperties: Set<CMIOExtensionProperty> { [.streamActiveFormatIndex, .streamFrameDuration] }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let p = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) { p.activeFormatIndex = 0 }
        if properties.contains(.streamFrameDuration) { p.frameDuration = CMTime(value: 1, timescale: Camera.fps) }
        return p
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {}
    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool { true }
    func startStream() throws { device.sourceStarted() }
    func stopStream() throws { device.sourceStopped() }
}

/// What Nearside writes the phone's picture into.
final class SinkSource: NSObject, CMIOExtensionStreamSource, @unchecked Sendable {
    private(set) var stream: CMIOExtensionStream!
    private let format: CMIOExtensionStreamFormat
    private unowned let device: DeviceSource
    private var client: CMIOExtensionClient?
    private var running = false

    init(_ format: CMIOExtensionStreamFormat, device: DeviceSource) {
        self.format = format
        self.device = device
        super.init()
        stream = CMIOExtensionStream(localizedName: "Nearside Camera Input", streamID: Camera.sinkID, direction: .sink,
                                     clockType: .hostTime, source: self)
    }

    var formats: [CMIOExtensionStreamFormat] { [format] }
    var availableProperties: Set<CMIOExtensionProperty> {
        [.streamActiveFormatIndex, .streamFrameDuration, .streamSinkBufferQueueSize, .streamSinkBuffersRequiredForStartup,
         .streamSinkBufferUnderrunCount, .streamSinkEndOfData, Camera.sinkKey]
    }

    /// The key last presented (once: it's cleared when a writer is authorized or refused).
    private var presented: String?

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let p = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) { p.activeFormatIndex = 0 }
        if properties.contains(.streamFrameDuration) { p.frameDuration = CMTime(value: 1, timescale: Camera.fps) }
        if properties.contains(.streamSinkBufferQueueSize) { p.sinkBufferQueueSize = 1 }
        if properties.contains(.streamSinkBuffersRequiredForStartup) { p.sinkBuffersRequiredForStartup = 1 }
        return p
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {
        if let key = streamProperties.propertiesDictionary[Camera.sinkKey]?.value as? String { presented = key }
    }

    /// Only Nearside: it writes a fresh random key into the app group's container (which only it
    /// and this extension can open; a sandboxed extension can't check other processes' code
    /// signatures, so this is the proof), presents the same key as a property, then starts. Each
    /// key works once. One writer at a time.
    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool {
        let offered = presented
        presented = nil
        guard let offered, !offered.isEmpty, offered == Self.storedKey() else {
            log.error("refused a sink writer without Nearside's key (pid \(client.pid, privacy: .public))")
            return false
        }
        if running, let current = self.client, current.clientID != client.clientID { return false }
        self.client = client
        return true
    }

    private static func storedKey() -> String? {
        guard let dir = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Camera.group) else {
            log.error("no app group container")
            return nil
        }
        return (try? String(contentsOf: dir.appendingPathComponent("sink-key"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func startStream() throws {
        running = true
        take()
    }

    func stopStream() throws {
        running = false
        client = nil
    }

    private func take() {
        guard running, let client else { return }
        stream.consumeSampleBuffer(from: client) { [weak self] buffer, sequence, _, _, _ in
            guard let self else { return }
            if let buffer {
                device.forward(buffer)
                stream.notifyScheduledOutputChanged(CMIOExtensionScheduledOutput(sequenceNumber: sequence,
                                                                                 hostTimeInNanoseconds: DeviceSource.now()))
            }
            take()
        }
    }
}

final class ProviderSource: NSObject, CMIOExtensionProviderSource {
    private(set) var provider: CMIOExtensionProvider!
    private let deviceSource = DeviceSource()

    override init() {
        super.init()
        provider = CMIOExtensionProvider(source: self, clientQueue: nil)
        do { try provider.addDevice(deviceSource.device) } catch { log.error("adding the device failed: \(error.localizedDescription)") }
    }

    func connect(to client: CMIOExtensionClient) throws {}
    func disconnect(from client: CMIOExtensionClient) {}
    var availableProperties: Set<CMIOExtensionProperty> { [.providerManufacturer] }

    func providerProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionProviderProperties {
        let p = CMIOExtensionProviderProperties(dictionary: [:])
        if properties.contains(.providerManufacturer) { p.manufacturer = "Nearside" }
        return p
    }

    func setProviderProperties(_ providerProperties: CMIOExtensionProviderProperties) throws {}
}

let providerSource = ProviderSource()
CMIOExtensionProvider.startService(provider: providerSource.provider)
CFRunLoopRun()
