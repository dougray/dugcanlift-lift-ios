import Foundation
import LiftCore

/// What Train shows under Outdoor: the last route and the personal bests.
///
/// A rule with no view in it, for the reason the rest of this app keeps such
/// rules out of `@State` — a best that counts an unfinished recording, or a
/// fastest pace set by a 40 m GPS blip, is a wrong number a person will chase.
enum OutdoorRecords {

    /// Shorter than this and a pace is mostly GPS noise: a few metres of drift
    /// on a short recording reads as a world-record mile.
    static let minimumPaceDistanceMeters = 1_000.0

    struct Bests: Equatable {
        let type: OutdoorActivityType
        let count: Int
        let longestDistanceMeters: Double?
        let longestDuration: TimeInterval?
        /// Seconds per metre, like `OutdoorActivity.averagePaceSecondsPerMeter`.
        /// Nil until one recording reaches `minimumPaceDistanceMeters`.
        let fastestPaceSecondsPerMeter: Double?
    }

    /// The newest finished activity with a route worth drawing. A recording
    /// still in progress has no end, and one with a single fix has no line.
    static func lastRoute(in activities: [OutdoorActivity]) -> OutdoorActivity? {
        activities
            .filter { $0.endedAt != nil }
            .sorted { $0.startedAt > $1.startedAt }
            .first { $0.routePoints.count > 1 }
    }

    /// One entry per type that has at least one finished activity, in the
    /// order the Start buttons appear. Blank stays blank: a type with no
    /// distance recorded has no farthest, rather than a farthest of zero.
    static func bests(in activities: [OutdoorActivity]) -> [Bests] {
        let finished = activities.filter { $0.endedAt != nil }
        return OutdoorActivityType.allCases.compactMap { type in
            let ofType = finished.filter { $0.activityType == type }
            guard !ofType.isEmpty else { return nil }

            let distance = ofType.map(\.distanceMeters).filter { $0 > 0 }.max()
            let duration = ofType.compactMap(\.duration).filter { $0 > 0 }.max()
            let pace = ofType
                .filter { $0.distanceMeters >= minimumPaceDistanceMeters }
                .compactMap(\.averagePaceSecondsPerMeter)
                .filter { $0 > 0 }
                .min()

            return Bests(type: type, count: ofType.count,
                         longestDistanceMeters: distance,
                         longestDuration: duration,
                         fastestPaceSecondsPerMeter: pace)
        }
    }

    // MARK: - Formatting

    /// "28:40", or "1:02:10" past the hour.
    static func durationText(_ duration: TimeInterval) -> String {
        let total = Int(duration.rounded())
        let hours = total / 3600, minutes = (total / 60) % 60, seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }

    /// "8:42 /mi" or "5:24 /km".
    static func paceText(_ secondsPerMeter: Double, unit: DistanceUnit) -> String {
        let perUnit = Int((secondsPerMeter * unit.toMeters(1)).rounded())
        return String(format: "%d:%02d /%@", perUnit / 60, perUnit % 60, unit.abbreviation)
    }

    /// "3.12 mi".
    static func distanceText(_ meters: Double, unit: DistanceUnit) -> String {
        String(format: "%.2f %@", unit.fromMeters(meters), unit.abbreviation)
    }
}

