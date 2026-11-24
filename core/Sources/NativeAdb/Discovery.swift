#if canImport(dnssd)
import dnssd
import Foundation

/// Finds phones on the network via mDNS (Bonjour), like `adb mdns services`:
/// `_adb-tls-connect._tcp` (wireless debugging) and `_adb-tls-pairing._tcp` (pairing).
public enum Discovery {
    public struct Service: Sendable, Equatable {
        public let name: String  // e.g. "adb-ABC123XYZ0001-AbCdEf" (carries the serial)
        public let host: String  // e.g. "Android-12.local."
        public let port: UInt16
    }

    public static let connectType = "_adb-tls-connect._tcp"
    public static let pairingType = "_adb-tls-pairing._tcp"

    /// Everything advertising `type` that answers within `timeout`.
    public static func browse(_ type: String, timeout: TimeInterval = 1.5) -> [Service] {
        let browser = Browser()
        var ref: DNSServiceRef?
        let context = Unmanaged.passUnretained(browser).toOpaque()
        guard DNSServiceBrowse(&ref, 0, 0, type, "local.", { _, flags, interface, error, name, type, domain, context in
            guard error == kDNSServiceErr_NoError, flags & UInt32(kDNSServiceFlagsAdd) != 0,
                  let name, let type, let domain, let context else { return }
            let browser = Unmanaged<Browser>.fromOpaque(context).takeUnretainedValue()
            browser.found.append((String(cString: name), String(cString: type), String(cString: domain), interface))
        }, context) == kDNSServiceErr_NoError, let ref else { return [] }
        defer { DNSServiceRefDeallocate(ref) }

        let deadline = Date().addingTimeInterval(timeout)
        pump(ref, until: deadline)

        // Resolve each name to host:port.
        var services: [Service] = []
        for (name, type, domain, interface) in browser.found {
            let resolver = Resolver()
            var rref: DNSServiceRef?
            let rcontext = Unmanaged.passUnretained(resolver).toOpaque()
            guard DNSServiceResolve(&rref, 0, interface, name, type, domain, { _, _, _, error, _, host, port, _, _, context in
                guard error == kDNSServiceErr_NoError, let host, let context else { return }
                let resolver = Unmanaged<Resolver>.fromOpaque(context).takeUnretainedValue()
                resolver.result = (String(cString: host), UInt16(bigEndian: port))
            }, rcontext) == kDNSServiceErr_NoError, let rref else { continue }
            pump(rref, until: Date().addingTimeInterval(1)) { resolver.result != nil }
            DNSServiceRefDeallocate(rref)
            if let (host, port) = resolver.result, !services.contains(where: { $0.name == name }) {
                services.append(Service(name: name, host: host, port: port))
            }
        }
        return services
    }

    /// Processes dns_sd replies until the deadline (or `done`).
    private static func pump(_ ref: DNSServiceRef, until deadline: Date, done: () -> Bool = { false }) {
        let fd = DNSServiceRefSockFD(ref)
        while !done() {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return }
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&pfd, 1, Int32(remaining * 1000)) > 0 else { return }
            guard DNSServiceProcessResult(ref) == kDNSServiceErr_NoError else { return }
        }
    }

    private final class Browser { var found: [(String, String, String, UInt32)] = [] }
    private final class Resolver { var result: (String, UInt16)? }
}
#endif
