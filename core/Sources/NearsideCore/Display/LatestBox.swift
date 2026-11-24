import Foundation

/// Hands the newest value from producers to one consumer thread: a value that hasn't been taken
/// yet is replaced by a newer one (frames: a late picture is worth nothing once the next is
/// there), so the consumer can never fall behind by more than one.
public final class LatestBox<Value>: @unchecked Sendable {
    private let condition = NSCondition()
    private var value: Value?
    private var closed = false

    public init() {}

    /// Puts a value in, replacing one still waiting. Never blocks.
    public func put(_ new: Value) {
        condition.lock()
        value = new
        condition.signal()
        condition.unlock()
    }

    /// The waiting value, waiting for one if there's none; nil once closed.
    public func take() -> Value? {
        condition.lock()
        defer { condition.unlock() }
        while value == nil && !closed { condition.wait() }
        guard !closed else { return nil }
        defer { value = nil }
        return value
    }

    /// Ends `take` for good (the consumer thread then finishes).
    public func close() {
        condition.lock()
        closed = true
        condition.broadcast()
        condition.unlock()
    }
}
