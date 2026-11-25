import Foundation
import NearsideCore
import Observation
import WindowsPlatform

// The engine for the C# app, as a C API (include/nearside.h). Everything runs on the app's UI
// thread, which is the process's main thread, so it is the engine's main actor too:
// - the app pumps the main queue and run loop (nearside_pump) when nearside_wake_handle is
//   signalled, and on a short timer for the run loop's timers;
// - events (JSON) go to the app's callback during a pump, on that same thread;
// - "changed" means a new snapshot (nearside_snapshot) is ready: what the interface shows.

public typealias NearsideEventCallback = @convention(c) (UnsafePointer<CChar>) -> Void

@MainActor
enum Bridge {
    static var engine: SyncEngine?
    static var onEvent: NearsideEventCallback?
    static var notifications: BridgeNotifications?
    /// The latest snapshot, rebuilt after each change the engine makes.
    static var snapshot = "{}"
    /// The panel is open: the phone's recent photos are watched and shown in it meanwhile.
    static var panelOpen = false

    static func emit(_ event: String, _ fields: [String: Any] = [:]) {
        guard let onEvent else { return }
        var object = fields
        object["e"] = event
        json(object).withCString { onEvent($0) }
    }

    static func json(_ object: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object), let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    /// Rebuilds the snapshot, and again whenever anything it read changes.
    static func observe() {
        guard let engine else { return }
        snapshot = withObservationTracking {
            json(Snapshot.make(engine))
        } onChange: {
            // Called before the change lands (willSet), maybe off the main thread: rebuild after it.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    observe()
                    emit("changed")
                }
            }
        }
    }
}

@_cdecl("nearside_start")
public func nearside_start(_ apkPath: UnsafePointer<CChar>?, _ callback: NearsideEventCallback) {
    let apk = apkPath.map { URL(fileURLWithPath: String(cString: $0)) }
    nonisolated(unsafe) let callback = callback // a C function pointer, called on this thread only
    MainActor.assumeIsolated {
        guard Bridge.engine == nil else { return }
        Bridge.onEvent = callback
        let platform = WindowsPlatform()
        platform.notifications = {
            let notifications = BridgeNotifications()
            Bridge.notifications = notifications
            return notifications
        }
        platform.videoDecoder = { codec in
            Media.lock.withLock {
                let decoder = BridgeDecoder(session: Media.opening, codec: codec)
                Media.decoders[Media.opening] = decoder
                return decoder
            }
        }
        platform.audioOutput = {
            let session = Media.lock.withLock { Media.opening }
            let output = BridgeAudio(session: session)
            AudioMedia.lock.withLock { AudioMedia.outputs[session] = output }
            return output
        }
        platform.microphone = { BridgeMicrophone() }
        Platforms.current = platform
        let engine = SyncEngine(apkURL: apk)
        engine.onArrival = { item in Bridge.emit("clip", ["id": item.id.uuidString]) }
        // "Open on PC" in a notification: its app in a window, opening that notification.
        engine.onOpenNotificationOnMac = { key, package, app in
            Bridge.emit("openInWindow", ["key": key, "package": package, "app": app])
        }
        Bridge.engine = engine
        engine.start()
        Bridge.observe()
        Bridge.emit("changed")
    }
}

#if os(Windows)
@_silgen_name("_dispatch_get_main_queue_handle_4CF")
private func dispatchMainQueueHandle() -> UnsafeMutableRawPointer?

/// Runs what's queued on the main queue (what the run loop calls when the handle is signalled).
@_silgen_name("_dispatch_main_queue_callback_4CF")
private func drainMainQueue(_ message: UnsafeMutableRawPointer?)
#endif

/// Signalled when the main queue has work: the app then calls nearside_pump.
@_cdecl("nearside_wake_handle")
public func nearside_wake_handle() -> UnsafeMutableRawPointer? {
    #if os(Windows)
    return dispatchMainQueueHandle()
    #else
    return nil
    #endif
}

/// Runs what's due on the main queue and the main run loop, without waiting. The main queue is
/// drained here directly: the run loop skips it whenever it has no timers or sources of its own.
@_cdecl("nearside_pump")
public func nearside_pump() {
    #if os(Windows)
    drainMainQueue(nil)
    #endif
    _ = RunLoop.main.run(mode: .default, before: Date())
}

/// How the engine sees the calling thread, as JSON (free it with nearside_free): for diagnosing the pump.
@_cdecl("nearside_debug")
public func nearside_debug() -> UnsafeMutablePointer<CChar>? {
    let info: [String: Any] = [
        "isMainThread": Thread.isMainThread,
        "mainRunLoopIsCurrent": RunLoop.main === RunLoop.current,
    ]
    return duplicate(MainActor.assumeIsolated { Bridge.json(info) })
}

/// A recent photo's thumbnail (JPEG), kept in memory only; free it with nearside_free. Null if none.
@_cdecl("nearside_photo_thumbnail")
public func nearside_photo_thumbnail(_ id: Int64, _ length: UnsafeMutablePointer<Int32>) -> UnsafeMutableRawPointer? {
    let data = MainActor.assumeIsolated { Bridge.engine?.photos.thumbnails[id] }
    guard let data, let copy = malloc(data.count) else { length.pointee = 0; return nil }
    data.copyBytes(to: copy.assumingMemoryBound(to: UInt8.self), count: data.count)
    length.pointee = Int32(data.count)
    return copy
}

/// What the interface shows, as JSON (free it with nearside_free).
@_cdecl("nearside_snapshot")
public func nearside_snapshot() -> UnsafeMutablePointer<CChar>? {
    duplicate(MainActor.assumeIsolated { Bridge.snapshot })
}

@_cdecl("nearside_free")
public func nearside_free(_ text: UnsafeMutablePointer<CChar>?) {
    free(text)
}

/// A command from the interface, as JSON: {"c": name, ...} (see Commands.swift).
@_cdecl("nearside_command")
public func nearside_command(_ json: UnsafePointer<CChar>) {
    let data = Data(String(cString: json).utf8)
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let name = object["c"] as? String else { return }
    MainActor.assumeIsolated { Commands.run(name, object) }
}

func duplicate(_ text: String) -> UnsafeMutablePointer<CChar>? {
    text.withCString { source in
        let length = strlen(source) + 1
        let copy = malloc(length)?.assumingMemoryBound(to: CChar.self)
        copy?.initialize(from: source, count: length)
        return copy
    }
}
