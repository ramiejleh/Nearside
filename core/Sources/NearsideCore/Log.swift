import Foundation
#if canImport(os)
import os
#endif

/// Log lines with no personal content: the unified log on the Mac (subsystem dev.nearside.mac),
/// NSLog elsewhere.
public struct Log: Sendable {
    private let category: String
    #if canImport(os)
    private let logger: Logger
    #endif

    public init(_ category: String) {
        self.category = category
        #if canImport(os)
        logger = Logger(subsystem: "dev.nearside.mac", category: category)
        #endif
    }

    /// Only shown while streaming the log live (not kept).
    public func info(_ message: String) {
        #if canImport(os)
        logger.info("\(message, privacy: .public)")
        #else
        NSLog("Nearside [\(category)]: \(message)")
        #endif
    }

    public func notice(_ message: String) {
        #if canImport(os)
        logger.notice("\(message, privacy: .public)")
        #else
        NSLog("Nearside [\(category)]: \(message)")
        #endif
    }

    public func error(_ message: String) {
        #if canImport(os)
        logger.error("\(message, privacy: .public)")
        #else
        NSLog("Nearside [\(category)]: error: \(message)")
        #endif
    }
}
