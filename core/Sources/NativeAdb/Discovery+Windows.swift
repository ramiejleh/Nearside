#if os(Windows)
import Foundation
import WinSDK

/// Finds phones on the network via mDNS, with Windows' own DnsServiceBrowse / DnsServiceResolve
/// (windns.h, Windows 10 1903+). Same API as the Mac's (Discovery.swift).
public enum Discovery {
    public struct Service: Sendable, Equatable {
        public let name: String  // e.g. "adb-ABC123XYZ0001-AbCdEf" (carries the serial)
        public let host: String  // an IPv4 address here (Windows resolves it with the service)
        public let port: UInt16
    }

    public static let connectType = "_adb-tls-connect._tcp"
    public static let pairingType = "_adb-tls-pairing._tcp"

    /// Everything advertising `type` that answers within `timeout`.
    public static func browse(_ type: String, timeout: TimeInterval = 1.5) -> [Service] {
        let suffix = ".\(type).local"
        // Resolving gets what's left of one deadline (a busy network can't stretch it), 1 s at most each.
        let deadline = Date().addingTimeInterval(timeout + 3)
        var services: [Service] = []
        for instance in browseInstances("\(type).local", suffix: suffix, timeout: timeout) {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { break }
            let name = String(instance.dropLast(suffix.count))
            guard isAdbName(name), let found = resolve(instance, timeout: min(1, remaining)) else { continue }
            if !services.contains(where: { $0.name == name }) {
                services.append(Service(name: name, host: found.host, port: found.port))
            }
        }
        return services
    }

    /// adb's service names are "adb-<serial>-<random>": letters, digits, "-" and "_" only.
    static func isAdbName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 128 && name.unicodeScalars.allSatisfy {
            ($0.isASCII && ($0.properties.isAlphabetic || ("0"..."9").contains($0))) || $0 == "-" || $0 == "_"
        }
    }

    /// Collects what the callbacks report. Shared with Windows' callback thread, under `lock`.
    private final class Box: @unchecked Sendable {
        let lock = NSLock()
        var names: [String] = []
        var suffix = ""
        var resolved: (host: String, port: UInt16)?
        let done = DispatchSemaphore(value: 0)
    }

    /// Full instance names ("adb-….\_adb-tls-connect.\_tcp.local") answering within `timeout`.
    private static func browseInstances(_ query: String, suffix: String, timeout: TimeInterval) -> [String] {
        let box = Box()
        box.suffix = suffix.lowercased()
        // Retained until Windows reports the browse cancelled (its last callback).
        let context = Unmanaged.passRetained(box).toOpaque()
        var cancel = DNS_SERVICE_CANCEL()
        let status: DWORD = query.withCString(encodedAs: UTF16.self) { name in
            var request = DNS_SERVICE_BROWSE_REQUEST()
            request.Version = DWORD(DNS_QUERY_REQUEST_VERSION1)
            request.InterfaceIndex = 0
            request.QueryName = name
            request.pBrowseCallback = { status, context, records in
                guard let context else { return }
                let box = Unmanaged<Box>.fromOpaque(context).takeUnretainedValue()
                if status == DWORD(ERROR_CANCELLED) {
                    Unmanaged<Box>.fromOpaque(context).release()
                    return
                }
                guard status == DWORD(ERROR_SUCCESS), let records else { return }
                defer { DnsFree(records, DnsFreeRecordList) } // DnsRecordListFree is a macro for this
                var record: PDNS_RECORD? = records
                while let r = record {
                    if r.pointee.wType == WORD(DNS_TYPE_PTR), let target = r.pointee.Data.PTR.pNameHost {
                        // Swift sees the ANSI DNS_RECORD, but this API is Unicode only: the name is UTF-16.
                        let name = String(decodingCString: UnsafeRawPointer(target).assumingMemoryBound(to: UInt16.self), as: UTF16.self)
                        box.lock.withLock {
                            // Only this service's names, and a bounded list whatever the network sends.
                            if name.lowercased().hasSuffix(box.suffix), box.names.count < 64, !box.names.contains(name) {
                                box.names.append(name)
                            }
                        }
                    }
                    record = r.pointee.pNext
                }
            }
            request.pQueryContext = context
            return DWORD(bitPattern: DnsServiceBrowse(&request, &cancel))
        }
        guard status == DWORD(DNS_REQUEST_PENDING) else {
            Unmanaged<Box>.fromOpaque(context).release()
            return []
        }
        Thread.sleep(forTimeInterval: timeout)
        DnsServiceBrowseCancel(&cancel)
        return box.lock.withLock { box.names }
    }

    /// An instance's IPv4 address and port.
    private static func resolve(_ instance: String, timeout: TimeInterval = 1) -> (host: String, port: UInt16)? {
        let box = Box()
        let context = Unmanaged.passRetained(box).toOpaque() // released by the completion callback
        var cancel = DNS_SERVICE_CANCEL()
        let status: DWORD = instance.withCString(encodedAs: UTF16.self) { name in
            var request = DNS_SERVICE_RESOLVE_REQUEST()
            request.Version = DWORD(DNS_QUERY_REQUEST_VERSION1)
            request.InterfaceIndex = 0
            request.QueryName = UnsafeMutablePointer(mutating: name)
            request.pResolveCompletionCallback = { status, context, instance in
                guard let context else { return }
                let box = Unmanaged<Box>.fromOpaque(context).takeRetainedValue()
                defer { box.done.signal() }
                guard let instance else { return }
                defer { DnsServiceFreeInstance(instance) }
                guard status == DWORD(ERROR_SUCCESS), let ip = instance.pointee.ip4Address else { return }
                // IP4_ADDRESS is in network byte order: its bytes are the address in order.
                let host = withUnsafeBytes(of: ip.pointee) { $0.map(String.init).joined(separator: ".") }
                box.lock.withLock { box.resolved = (host, instance.pointee.wPort) }
            }
            request.pQueryContext = context
            return DWORD(bitPattern: DnsServiceResolve(&request, &cancel))
        }
        guard status == DWORD(DNS_REQUEST_PENDING) else {
            Unmanaged<Box>.fromOpaque(context).release()
            return nil
        }
        if box.done.wait(timeout: .now() + timeout) == .timedOut {
            DnsServiceResolveCancel(&cancel) // the callback still runs once, cancelled
            return nil
        }
        return box.lock.withLock { box.resolved }
    }
}
#endif
