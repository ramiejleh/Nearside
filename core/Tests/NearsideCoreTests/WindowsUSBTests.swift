@testable import NativeAdb
import Testing

/// Finding the phone's serial in Windows' device IDs (USB+Windows.swift).
@Suite struct WindowsUSBTests {
    @Test func serialFromTheDevice() {
        #expect(WindowsUSBInstance.serial(#"USB\VID_18D1&PID_4EE7\0A281JEC211234"#) == "0A281JEC211234")
        #expect(WindowsUSBInstance.serial(#"usb\vid_04e8&pid_6860\R58M12ABCDE"#) == "R58M12ABCDE")
    }

    @Test func noSerialInAnInterfaceOrAMadeUpID() {
        #expect(WindowsUSBInstance.serial(#"USB\VID_18D1&PID_4EE7&MI_01\7&2A3B4C5D&0&0001"#) == nil) // a composite device's interface
        #expect(WindowsUSBInstance.serial(#"USB\VID_18D1&PID_4EE7\5&1A2B3C&0&2"#) == nil) // Windows' own: no serial
        #expect(WindowsUSBInstance.serial(#"USB\VID_18D1&PID_4EE7\"#) == nil)
        #expect(WindowsUSBInstance.serial(#"HID\VID_18D1&PID_4EE7\ABC"#) == nil)
        #expect(WindowsUSBInstance.serial(#"USB\VID_18D1\PID_4EE7\ABC"#) == nil)
    }
}
