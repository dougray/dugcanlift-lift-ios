import Foundation

/// Rest between sets.
///
/// Deliberately not a `Timer`: watchOS suspends the app between glances, so
/// the countdown is derived from a start date instead of a tick that stops
/// firing when the wrist drops.
public struct RestTimer: Equatable, Sendable {

    public var interval: TimeInterval
    public private(set) var startedAt: Date?

    public init(interval: TimeInterval = 90, startedAt: Date? = nil) {
        self.interval = interval
        self.startedAt = startedAt
    }

    public var isRunning: Bool { startedAt != nil }

    public mutating func start(at date: Date = Date()) {
        startedAt = date
    }

    public mutating func stop() {
        startedAt = nil
    }

    /// Seconds left, or `nil` when the timer has not been started.
    public func remaining(at date: Date = Date()) -> TimeInterval? {
        guard let startedAt else { return nil }
        return max(0, interval - date.timeIntervalSince(startedAt))
    }

    public func hasFinished(at date: Date = Date()) -> Bool {
        guard let remaining = remaining(at: date) else { return false }
        return remaining <= 0
    }

    /// Fraction elapsed, 0...1, for a progress ring.
    public func progress(at date: Date = Date()) -> Double {
        guard interval > 0, let remaining = remaining(at: date) else { return 0 }
        return min(1, max(0, 1 - remaining / interval))
    }

    /// "01:37"
    public static func format(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds).rounded())
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
