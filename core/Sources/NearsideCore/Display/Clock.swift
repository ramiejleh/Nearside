import Dispatch

/// Microseconds on the monotonic clock (on the Mac the same base as CACurrentMediaTime: both count
/// mach_absolute_time).
public func monotonicMicros() -> Int64 { Int64(DispatchTime.now().uptimeNanoseconds / 1000) }
