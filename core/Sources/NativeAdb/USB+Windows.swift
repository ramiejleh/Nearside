import Foundation

/// The serial number in a Windows USB device instance ID ("USB\VID_18D1&PID_4EE7\<serial>").
/// Windows makes up an ID with "&" in it when a device has no usable serial, and a composite
/// device's interfaces ("…&MI_01\7&2a3b…&0&0001") have IDs of their own: neither carries one.
enum WindowsUSBInstance {
    static func serial(_ instanceID: String) -> String? {
        let parts = instanceID.split(separator: "\\", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].uppercased() == "USB", !parts[2].isEmpty, !parts[2].contains("&") else { return nil }
        return String(parts[2])
    }
}

#if os(Windows)
import WinSDK
import WinSDK.WinUSB
import CWinDevices

/// adb over a USB cable with WinUSB: the phone's adb interface, which adbd itself tells Windows
/// to give to WinUSB (Microsoft OS descriptors: compatible ID "WINUSB" and adb's interface GUID),
/// so no driver needs installing; phones whose maker's driver is installed show the same GUID.
/// The same protocol as the Mac's (USB.swift): no TLS, the phone checks this PC's key (AUTH),
/// and the caller checks it's the paired phone.
public enum USB {
    /// A phone's adb interface, as Windows lists it right now.
    public struct Device: Sendable, Equatable {
        /// The phone's serial number (its USB serial string, the same as ro.serialno).
        public let serial: String
        /// New each time the phone is plugged in (from when Windows last saw it arrive).
        public let id: UInt64
        let path: String
    }

    /// ANDROID_USB_CLASS_ID, the device interface adb's interface is registered under.
    static let adbInterface = GUID(Data1: 0xF72F_E0D4, Data2: 0xCBCB, Data3: 0x407D, Data4: (0x88, 0x14, 0x9E, 0xD6, 0x73, 0xD0, 0xDD, 0x6B))
    // devpkey.h
    static let instanceIDKey = NSDEVPROPKEY(fmtid: GUID(Data1: 0x78C3_4FC8, Data2: 0x104A, Data3: 0x4ACA, Data4: (0x9E, 0xA4, 0x52, 0x4D, 0x52, 0x99, 0x6E, 0x57)), pid: 256)
    static let lastArrivalKey = NSDEVPROPKEY(fmtid: GUID(Data1: 0x83DA_6326, Data2: 0x97A6, Data3: 0x4088, Data4: (0x94, 0x53, 0xA1, 0x92, 0x3F, 0x57, 0x3B, 0x29)), pid: 102)
    static let stringType: ULONG = 0x12, fileTimeType: ULONG = 0x10 // DEVPROP_TYPE_STRING, _FILETIME
    // cfgmgr32.h
    static let success: NSCONFIGRET = 0, bufferSmall: NSCONFIGRET = 0x1A, maxDeviceIDLength = 200
    static let presentOnly: ULONG = 0 // CM_GET_DEVICE_INTERFACE_LIST_PRESENT

    /// adb interfaces plugged in now (cheap: Windows' own device list, the phone isn't asked).
    public static func devices() -> [Device] {
        interfacePaths().compactMap(describe)
    }

    private static func interfacePaths() -> [String] {
        var guid = adbInterface
        for _ in 0..<3 { // the list can grow between asking its size and reading it
            var size: ULONG = 0
            guard CM_Get_Device_Interface_List_SizeW(&size, &guid, nil, presentOnly) == success,
                  size > 1 else { return [] }
            var list = [WCHAR](repeating: 0, count: Int(size))
            let result = CM_Get_Device_Interface_ListW(&guid, nil, &list, size, presentOnly)
            if result == bufferSmall { continue }
            guard result == success else { return [] }
            // One string after another, ending with an empty one.
            return list.split(separator: 0).map { String(decoding: $0, as: UTF16.self) }
        }
        return []
    }

    /// The serial is in the ID of the device the interface belongs to (its parent, on a phone
    /// with more than adb on the cable).
    private static func describe(_ path: String) -> Device? {
        guard let instance = interfaceString(path, instanceIDKey) else { return nil }
        var node: NSDEVINST = 0
        var wide = Array(instance.utf16) + [0]
        guard CM_Locate_DevNodeW(&node, &wide, 0) == success else { return nil }
        var hasher = Hasher()
        hasher.combine(path)
        hasher.combine(arrival(node))
        let id = UInt64(bitPattern: Int64(hasher.finalize()))
        var current = node, currentID = instance
        for _ in 0..<2 {
            if let serial = WindowsUSBInstance.serial(currentID) { return Device(serial: serial, id: id, path: path) }
            var parent: NSDEVINST = 0
            guard CM_Get_Parent(&parent, current, 0) == success, let parentID = deviceID(parent) else { return nil }
            current = parent
            currentID = parentID
        }
        return nil
    }

    private static func interfaceString(_ path: String, _ key: NSDEVPROPKEY) -> String? {
        var key = key
        return path.withCString(encodedAs: UTF16.self) { name -> String? in
            var type: ULONG = 0, size: ULONG = 0
            _ = CM_Get_Device_Interface_PropertyW(name, &key, &type, nil, &size, 0) // the size
            guard size >= 2 else { return nil }
            var bytes = [UInt8](repeating: 0, count: Int(size) + 2) // room for a terminator
            guard CM_Get_Device_Interface_PropertyW(name, &key, &type, &bytes, &size, 0) == success,
                  type == stringType else { return nil }
            return bytes.withUnsafeBytes { String(decodingCString: $0.bindMemory(to: UInt16.self).baseAddress!, as: UTF16.self) }
        }
    }

    private static func deviceID(_ node: NSDEVINST) -> String? {
        var buffer = [WCHAR](repeating: 0, count: maxDeviceIDLength + 1)
        guard CM_Get_Device_IDW(node, &buffer, ULONG(buffer.count), 0) == success else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }, as: UTF16.self)
    }

    /// When Windows last saw the device arrive (a FILETIME), 0 if unknown.
    private static func arrival(_ node: NSDEVINST) -> UInt64 {
        var key = lastArrivalKey, type: ULONG = 0, value: UInt64 = 0
        var size = ULONG(MemoryLayout<UInt64>.size)
        let result = withUnsafeMutableBytes(of: &value) {
            CM_Get_DevNode_PropertyW(node, &key, &type, $0.baseAddress!.assumingMemoryBound(to: BYTE.self), &size, 0)
        }
        return result == success && type == fileTimeType ? value : 0
    }

    /// Opens `device`'s adb interface. Fails if it's gone or another program holds it (stock adb's
    /// server, Android Studio: WinUSB lets one program have it).
    static func open(_ device: Device) throws -> USBChannel {
        guard devices().contains(device) else { throw AdbError.connect("the phone isn't plugged in") }
        return try USBChannel(path: device.path)
    }
}

/// Bytes over the adb interface's bulk pipes, as on the Mac (USB.swift): each packet's 24-byte
/// header in a transfer of its own, then the payload; WinUSB adds the zero-length packet after a
/// write that fills whole USB packets (SHORT_PACKET_TERMINATE). Transfers are overlapped so
/// `close` can abort one in progress: a transfer starts, or `close` aborts them, under `ioLock`,
/// so none can start unnoticed after the abort.
final class USBChannel: Channel, @unchecked Sendable {
    private let file: HANDLE
    private let usb: WINUSB_INTERFACE_HANDLE
    private let inPipe: UCHAR, outPipe: UCHAR
    private let ioLock = NSLock()
    private var closed = false // under ioLock
    private let readLock = NSLock(), writeLock = NSLock() // one transfer each way at a time
    private let readOverlapped = UnsafeMutablePointer<OVERLAPPED>.allocate(capacity: 1)
    private let writeOverlapped = UnsafeMutablePointer<OVERLAPPED>.allocate(capacity: 1)

    init(path: String) throws {
        // GENERIC_READ | GENERIC_WRITE; FILE_FLAG_OVERLAPPED (WinUSB needs it).
        let handle = path.withCString(encodedAs: UTF16.self) {
            CreateFileW($0, 0x8000_0000 | 0x4000_0000, DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE), nil, DWORD(OPEN_EXISTING),
                        DWORD(FILE_ATTRIBUTE_NORMAL) | 0x4000_0000, nil)
        }
        guard let handle, handle != INVALID_HANDLE_VALUE else {
            let error = GetLastError()
            if error == DWORD(ERROR_ACCESS_DENIED) || error == DWORD(ERROR_SHARING_VIOLATION) || error == DWORD(ERROR_BUSY) {
                throw AdbError.connect("the phone's USB connection is in use by another program (quit Android Studio, or run `adb kill-server`)")
            }
            throw AdbError.connect("can't open the phone's USB connection (\(error))")
        }
        var opened: PVOID? = nil
        guard WinUsb_Initialize(handle, &opened), let usb = opened else {
            CloseHandle(handle)
            throw AdbError.connect("can't open the phone's USB connection with WinUSB (\(GetLastError()))")
        }
        var interface = USB_INTERFACE_DESCRIPTOR()
        var inPipe: UCHAR?, outPipe: UCHAR?
        if WinUsb_QueryInterfaceSettings(usb, 0, &interface),
           // adb's interface (vendor class 0xFF, subclass 0x42, protocol 1), not fastboot's (protocol 3)
           interface.bInterfaceClass == 0xFF, interface.bInterfaceSubClass == 0x42, interface.bInterfaceProtocol == 1 {
            for index in 0..<interface.bNumEndpoints {
                var pipe = WINUSB_PIPE_INFORMATION()
                guard WinUsb_QueryPipe(usb, 0, index, &pipe), pipe.PipeType == UsbdPipeTypeBulk else { continue }
                if pipe.PipeId & 0x80 != 0 { inPipe = pipe.PipeId } else { outPipe = pipe.PipeId }
            }
        }
        guard let inPipe, let outPipe else {
            WinUsb_Free(usb)
            CloseHandle(handle)
            throw AdbError.connect("the phone's adb interface has no bulk pipes")
        }
        var terminate: UCHAR = 1
        WinUsb_SetPipePolicy(usb, outPipe, ULONG(SHORT_PACKET_TERMINATE), ULONG(MemoryLayout<UCHAR>.size), &terminate)
        var timeout: ULONG = 10_000 // writes, as on the Mac; reads wait as long as it takes
        WinUsb_SetPipePolicy(usb, outPipe, ULONG(PIPE_TRANSFER_TIMEOUT), ULONG(MemoryLayout<ULONG>.size), &timeout)
        file = handle
        self.usb = usb
        self.inPipe = inPipe
        self.outPipe = outPipe
        for overlapped in [readOverlapped, writeOverlapped] {
            overlapped.initialize(to: OVERLAPPED())
            overlapped.pointee.hEvent = CreateEventW(nil, true, false, nil)
        }
    }

    deinit {
        WinUsb_Free(usb)
        CloseHandle(file)
        for overlapped in [readOverlapped, writeOverlapped] {
            CloseHandle(overlapped.pointee.hEvent)
            overlapped.deallocate()
        }
    }

    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        guard let base = buffer.baseAddress, buffer.count > 0 else { return 0 }
        return try readLock.withLock {
            while true {
                let n = try transfer(inPipe, base, buffer.count, readOverlapped, reading: true)
                if n > 0 { return n } // 0: a zero-length packet ending the last payload
            }
        }
    }

    func write(_ data: Data) throws {
        try writeLock.withLock {
            // Packets arrive whole (AdbConnection.send): header, then payload.
            try send(data.prefix(24))
            if data.count > 24 { try send(data.dropFirst(24)) }
        }
    }

    private func send(_ bytes: Data) throws {
        var copy = bytes // WinUSB's write takes a mutable buffer
        try copy.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            guard try transfer(outPipe, base, raw.count, writeOverlapped, reading: false) == raw.count else { throw AdbError.closed }
        }
    }

    private func transfer(_ pipe: UCHAR, _ buffer: UnsafeMutableRawPointer, _ count: Int,
                          _ overlapped: UnsafeMutablePointer<OVERLAPPED>, reading: Bool) throws -> Int {
        try ioLock.withLock {
            guard !closed else { throw AdbError.closed }
            let event = overlapped.pointee.hEvent
            overlapped.initialize(to: OVERLAPPED())
            overlapped.pointee.hEvent = event
            ResetEvent(event)
            let bytes = buffer.assumingMemoryBound(to: UCHAR.self)
            let started = reading ? WinUsb_ReadPipe(usb, pipe, bytes, ULONG(count), nil, overlapped)
                                  : WinUsb_WritePipe(usb, pipe, bytes, ULONG(count), nil, overlapped)
            guard started || GetLastError() == DWORD(ERROR_IO_PENDING) else { throw AdbError.closed } // unplugged
        }
        var n: ULONG = 0
        guard WinUsb_GetOverlappedResult(usb, overlapped, &n, true) else { throw AdbError.closed } // unplugged, or closed
        return Int(n)
    }

    /// Aborts transfers in progress (the reader thread ends); nothing starts after.
    func close() {
        ioLock.withLock {
            guard !closed else { return }
            closed = true
            WinUsb_AbortPipe(usb, inPipe)
            WinUsb_AbortPipe(usb, outPipe)
        }
    }
}
#endif
