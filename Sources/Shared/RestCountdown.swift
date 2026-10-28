import Foundation
import ActivityKit

/// One rest between sets on the iPhone: when it started and when it is over.
///
/// In `Sources/Shared` because the widget extension draws it too, as the Live
/// Activity's content. A rest is an end time, not a number of seconds left,
/// so it stays right while LIFT is suspended and the lock screen counts it
/// down with no help from the app.
struct RestCountdown: Codable, Hashable {
    var startedAt: Date
    var endsAt: Date
    /// The set whose tick started it, so unticking that set takes it back.
    var setID: UUID?
    /// What the rest is before, for the notification and the lock screen.
    var exerciseName: String?

    /// Fifteen minutes, as long as anyone rests between sets on purpose.
    static let longest: TimeInterval = 15 * 60

    init(seconds: TimeInterval, setID: UUID?, exerciseName: String?, now: Date) {
        startedAt = now
        endsAt = now.addingTimeInterval(min(max(0, seconds), Self.longest))
        self.setID = setID
        self.exerciseName = exerciseName
    }

    func remaining(at now: Date) -> TimeInterval { max(0, endsAt.timeIntervalSince(now)) }

    func isOver(at now: Date) -> Bool { now >= endsAt }

    /// Fifteen seconds more or less. Never below nothing left and never past
    /// `longest` from now; added to a rest already over, it counts from now.
    func adjusted(by seconds: TimeInterval, now: Date) -> RestCountdown {
        var copy = self
        let left = remaining(at: now) + seconds
        copy.endsAt = now.addingTimeInterval(min(max(0, left), Self.longest))
        return copy
    }

    /// "1:35". Rounded up, so it never reads 0:00 with time still left.
    static func clock(_ seconds: TimeInterval) -> String {
        let whole = Int(seconds.rounded(.up))
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }
}

/// The Live Activity for a rest. Nothing is fixed for its whole life except
/// that it is LIFT's rest timer, so everything is in the content state.
struct RestActivityAttributes: ActivityAttributes {
    typealias ContentState = RestCountdown
}
