import CoreGraphics
import Foundation

/// The time sources `SessionManager` decides with, injectable so tests control them.
public struct SessionClock: Sendable {
    public var now: @Sendable () -> Date
    /// When the Mac last booted, or `nil` when unknown (which counts as a restart).
    public var bootTime: @Sendable () -> Date?
    /// Seconds since the last keyboard or mouse input anywhere in this login session.
    public var idleTime: @Sendable () -> TimeInterval

    public init(
        now: @escaping @Sendable () -> Date, bootTime: @escaping @Sendable () -> Date?,
        idleTime: @escaping @Sendable () -> TimeInterval
    ) {
        self.now = now
        self.bootTime = bootTime
        self.idleTime = idleTime
    }

    public static let system = SessionClock(
        now: { Date() }, bootTime: { systemBootTime() }, idleTime: { systemIdleTime() })

    /// `kern.boottime`.
    static func systemBootTime() -> Date? {
        var time = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &time, &size, nil, 0) == 0, time.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(time.tv_sec) + TimeInterval(time.tv_usec) / 1_000_000)
    }

    /// Needs no Accessibility or Input Monitoring permission. If the input type is unavailable, the Mac counts
    /// as idle forever, so the idle lock fails closed.
    static func systemIdleTime() -> TimeInterval {
        // kCGAnyInputEventType
        guard let anyInput = CGEventType(rawValue: ~0) else { return .infinity }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
    }
}
