import Foundation
import LiftCore

/// The numbers a run in progress shows: time, distance and pace.
///
/// The Train card and the full recording screen both read this, so they can
/// never disagree. A value type with no view in it, for the reason
/// `RecordingLifecycle` is one: a rule in a view cannot be tested, and two
/// views each carrying their own arithmetic is how two screens come to show
/// two paces.
struct LiveRunStats: Equatable {
    /// Under this far, a pace is GPS noise, not a speed.
    static let minimumPaceDistanceMeters = 10.0

    var elapsed: TimeInterval
    var distanceMeters: Double
    /// Seconds per meter; nil until the run has covered `minimumPaceDistanceMeters`.
    var paceSecondsPerMeter: Double?

    static func compute(points: [RoutePoint], startedAt: Date, now: Date) -> LiveRunStats {
        let elapsed = max(0, now.timeIntervalSince(startedAt))
        let distance = OutdoorActivityMath.totalDistanceMeters(points)
        let pace: Double? = distance >= minimumPaceDistanceMeters && elapsed > 0
            ? elapsed / distance
            : nil
        return LiveRunStats(elapsed: elapsed, distanceMeters: distance, paceSecondsPerMeter: pace)
    }

    // MARK: - Text, shared by the card and the full screen

    /// "0:00", "28:40", "1:02:10".
    var elapsedText: String { OutdoorRecords.durationText(elapsed) }

    func distanceText(unit: DistanceUnit) -> String {
        OutdoorRecords.distanceText(distanceMeters, unit: unit)
    }

    /// "8:42 /mi", or "\u{2014}" while there is no pace to show.
    func paceText(unit: DistanceUnit) -> String {
        paceSecondsPerMeter.map { OutdoorRecords.paceText($0, unit: unit) } ?? "\u{2014}"
    }
}
