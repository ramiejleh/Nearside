import Foundation

/// Debug tracing for the phone-app pipeline: NEARSIDE_TRACE=<file> appends timestamped lines.
public enum Trace {
    private static let handle: FileHandle? = {
        guard let path = ProcessInfo.processInfo.environment["NEARSIDE_TRACE"] else { return nil }
        FileManager.default.createFile(atPath: path, contents: nil)
        return FileHandle(forWritingAtPath: path)
    }()
    private static let lock = NSLock()

    public static var enabled: Bool { handle != nil }
    public static var path: String? { ProcessInfo.processInfo.environment["NEARSIDE_TRACE"] }

    public static func log(_ message: @autoclosure () -> String) {
        guard let handle else { return }
        let line = "\(monotonicMicros() / 1000) \(message())\n"
        lock.withLock { handle.write(Data(line.utf8)) }
    }
}
