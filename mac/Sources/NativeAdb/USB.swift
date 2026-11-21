import Foundation
import IOKit
import IOUSBHost

/// adb over a USB cable: the phone's adb interface (vendor class 0xFF, subclass 0x42, protocol 1)
/// with one bulk endpoint each way, as AOSP adb's client/usb_osx.cpp uses it. No TLS on a cable:
/// the phone checks this Mac's RSA key (AUTH), and the caller checks it's the paired phone.
public enum USB {
    /// A phone's adb interface, as the Mac sees it right now.
    public struct Device: Sendable, Equatable {
        /// The phone's serial number (its USB serial string, the same as ro.serialno).
        public let serial: String
        /// IORegistry entry ID: a new one each time the phone is plugged in.
        public let id: UInt64
    }

    static func matching() -> CFMutableDictionary {
        IOUSBHostInterface.__createMatchingDictionary(
            withVendorID: nil, productID: nil, bcdDevice: nil, interfaceNumber: nil, configurationValue: nil,
            interfaceClass: 0xFF, interfaceSubclass: 0x42, interfaceProtocol: 1, speed: nil, productIDArray: nil
        ).takeRetainedValue()
    }

    /// adb interfaces plugged in now (cheap: the Mac's own device list, the phone isn't asked).
    public static func devices() -> [Device] {
        var found: [Device] = []
        forEachInterface { service in
            if let device = describe(service) { found.append(device) }
            return true
        }
        return found
    }

    private static func forEachInterface(_ body: (io_service_t) -> Bool) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching(), &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }
        while case let service = IOIteratorNext(iterator), service != 0 {
            let more = body(service)
            IOObjectRelease(service)
            if !more { break }
        }
    }

    private static func describe(_ service: io_service_t) -> Device? {
        var id: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(service, &id)
        for key in ["kUSBSerialNumberString", "USB Serial Number"] {
            let value = IORegistryEntrySearchCFProperty(service, kIOServicePlane, key as CFString, kCFAllocatorDefault,
                                                        IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents))
            if let serial = value as? String, !serial.isEmpty { return Device(serial: serial, id: id) }
        }
        return nil
    }

    /// Opens `device`'s adb interface. Fails if it's gone or another program holds it (stock adb's
    /// server, Android Studio: the interface is exclusive).
    static func open(_ device: Device) throws -> USBChannel {
        var channel: USBChannel?
        var failure: Error = AdbError.connect("the phone isn't plugged in")
        forEachInterface { service in
            guard describe(service) == device else { return true }
            do { channel = try USBChannel(service: service) } catch { failure = error }
            return false
        }
        guard let channel else { throw failure }
        return channel
    }
}

/// Bytes over the adb interface's bulk pipes. adbd wants each packet's 24-byte header in a
/// transfer of its own, then the payload; and a zero-length packet after a write that fills
/// whole USB packets (or it waits for more). Reads ask for exactly what `Packet.read` wants.
final class USBChannel: Channel, @unchecked Sendable {
    private let interface: IOUSBHostInterface
    private let inPipe: IOUSBHostPipe
    private let outPipe: IOUSBHostPipe
    private let outPacketSize: Int
    private let writeLock = NSLock() // header + payload + zero-length packet stay together

    init(service: io_service_t) throws {
        do {
            interface = try IOUSBHostInterface(__ioService: service, options: [], queue: nil, interestHandler: nil)
        } catch {
            throw AdbError.connect("the phone's USB connection is in use by another program (quit Android Studio, or run `adb kill-server`)")
        }
        var inAddress: Int?, outAddress: Int?
        let configuration = interface.configurationDescriptor, interfaceDescriptor = interface.interfaceDescriptor
        var current = UnsafeRawPointer(interfaceDescriptor).assumingMemoryBound(to: IOUSBDescriptorHeader.self)
        while let endpoint = IOUSBGetNextEndpointDescriptor(configuration, interfaceDescriptor, current) {
            if IOUSBGetEndpointType(endpoint) == UInt8(kIOUSBEndpointTypeBulk.rawValue) {
                let address = Int(IOUSBGetEndpointAddress(endpoint))
                if IOUSBGetEndpointDirection(endpoint) == UInt8(kIOUSBEndpointDirectionIn.rawValue) { inAddress = address } else { outAddress = address }
            }
            current = UnsafeRawPointer(endpoint).assumingMemoryBound(to: IOUSBDescriptorHeader.self)
        }
        guard let inAddress, let outAddress else {
            interface.destroy()
            throw AdbError.connect("the phone's adb interface has no bulk pipes")
        }
        do {
            inPipe = try interface.copyPipe(withAddress: inAddress)
            outPipe = try interface.copyPipe(withAddress: outAddress)
        } catch {
            interface.destroy()
            throw AdbError.connect("can't open the phone's USB pipes (\(error.localizedDescription))")
        }
        outPacketSize = max(Int(outPipe.descriptors.pointee.descriptor.wMaxPacketSize), 64)
    }

    deinit { interface.destroy() }

    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        guard let base = buffer.baseAddress, buffer.count > 0 else { return 0 }
        while true {
            let data = NSMutableData(bytesNoCopy: base, length: buffer.count, freeWhenDone: false)
            var n = 0
            do {
                try inPipe.__sendIORequest(with: data, bytesTransferred: &n, completionTimeout: 0)
            } catch {
                throw AdbError.closed // unplugged, or closed
            }
            if n > 0 { return n } // 0: a zero-length packet ending the last payload
        }
    }

    func write(_ data: Data) throws {
        try writeLock.withLock {
            // Packets arrive whole (AdbConnection.send): header, then payload.
            try transfer(data.prefix(24))
            if data.count > 24 { try transfer(data.dropFirst(24)) }
        }
    }

    private func transfer(_ bytes: Data) throws {
        try bytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            let data = NSMutableData(bytesNoCopy: UnsafeMutableRawPointer(mutating: base), length: raw.count, freeWhenDone: false)
            var n = 0
            do {
                try outPipe.__sendIORequest(with: data, bytesTransferred: &n, completionTimeout: 10)
                if raw.count % outPacketSize == 0 {
                    try outPipe.__sendIORequest(with: nil, bytesTransferred: nil, completionTimeout: 10)
                }
            } catch {
                throw AdbError.closed
            }
            guard n == raw.count else { throw AdbError.closed }
        }
    }

    func close() { interface.destroy() } // aborts pending reads: the reader thread ends
}
