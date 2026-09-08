import XCTest
@testable import LiftKit

/// Covers `OutdoorActivity`'s own mutators — `finish(at:)` and
/// `appendPoint(_:)` — in isolation from `OutdoorActivityStore`'s
/// reconciliation rules (see `OutdoorActivityStoreTests`) and from any
/// HealthKit/CLLocationManager machinery (see `OutdoorActivityRecorder`,
/// which has no automated tests — it needs the Watch Simulator or a device).
final class OutdoorActivityTests: XCTestCase {

    private func point(lat: Double, lon: Double, altitude: Double = 0, at date: Date) -> RoutePoint {
        RoutePoint(
            latitude: lat, longitude: lon, altitudeMeters: altitude,
            recordedAt: date, horizontalAccuracyMeters: 5, verticalAccuracyMeters: 5
        )
    }

    // MARK: - finish(at:)

    func testFinishSetsEndedAtAndBumpsRevision() {
        var activity = OutdoorActivity(activityType: .run, startedAt: Date(timeIntervalSince1970: 0))
        let revisionBefore = activity.revision

        XCTAssertTrue(activity.finish(at: Date(timeIntervalSince1970: 100)))

        XCTAssertEqual(activity.endedAt, Date(timeIntervalSince1970: 100))
        XCTAssertEqual(activity.updatedAt, Date(timeIntervalSince1970: 100))
        XCTAssertEqual(activity.revision, revisionBefore + 1)
        XCTAssertTrue(activity.isFinished)
    }

    func testFinishingTwiceIsANoOp() {
        var activity = OutdoorActivity(activityType: .hike, startedAt: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(activity.finish(at: Date(timeIntervalSince1970: 10)))
        let revisionAfterFirstFinish = activity.revision

        XCTAssertFalse(activity.finish(at: Date(timeIntervalSince1970: 20)))

        XCTAssertEqual(activity.revision, revisionAfterFirstFinish)
        XCTAssertEqual(activity.endedAt, Date(timeIntervalSince1970: 10))
    }

    // MARK: - appendPoint(_:)

    func testAppendingFirstPointAddsNoDistance() {
        var activity = OutdoorActivity(activityType: .run, startedAt: Date(timeIntervalSince1970: 0))
        let revisionBefore = activity.revision

        XCTAssertTrue(activity.appendPoint(point(lat: 37.0, lon: -122.0, at: Date(timeIntervalSince1970: 1))))

        XCTAssertEqual(activity.routePoints.count, 1)
        XCTAssertEqual(activity.distanceMeters, 0)
        XCTAssertEqual(activity.revision, revisionBefore + 1)
    }

    func testAppendingPointsAccumulatesIncrementalDistance() {
        var activity = OutdoorActivity(activityType: .run, startedAt: Date(timeIntervalSince1970: 0))
        let p1 = point(lat: 37.0, lon: -122.0, at: Date(timeIntervalSince1970: 1))
        let p2 = point(lat: 37.001, lon: -122.0, at: Date(timeIntervalSince1970: 2))
        let p3 = point(lat: 37.002, lon: -122.0, at: Date(timeIntervalSince1970: 3))

        activity.appendPoint(p1)
        activity.appendPoint(p2)
        activity.appendPoint(p3)

        // The incremental running total must equal a from-scratch sum over
        // the whole route — that equivalence is the entire point of doing it
        // incrementally instead of by full resummation on every tick.
        let expected = OutdoorActivityMath.totalDistanceMeters([p1, p2, p3])
        XCTAssertEqual(activity.distanceMeters, expected, accuracy: 0.0001)
        XCTAssertGreaterThan(activity.distanceMeters, 0)
    }

    func testAppendingPointsRecomputesElevationGainToMatchFullRecalculation() {
        var activity = OutdoorActivity(activityType: .hike, startedAt: Date(timeIntervalSince1970: 0))
        let points = [
            point(lat: 37.0, lon: -122.0, altitude: 100, at: Date(timeIntervalSince1970: 0)),
            point(lat: 37.001, lon: -122.0, altitude: 100.5, at: Date(timeIntervalSince1970: 1)), // jitter, filtered
            point(lat: 37.002, lon: -122.0, altitude: 105, at: Date(timeIntervalSince1970: 2)),   // real climb
            point(lat: 37.003, lon: -122.0, altitude: 104, at: Date(timeIntervalSince1970: 3)),   // jitter, filtered
        ]

        for p in points { activity.appendPoint(p) }

        let expected = OutdoorActivityMath.elevationGainMeters(points)
        XCTAssertEqual(activity.elevationGainMeters, expected, accuracy: 0.0001)
        XCTAssertGreaterThan(activity.elevationGainMeters, 0)
    }

    func testAppendingAfterFinishIsRejectedWithoutBumpingRevisionOrDistance() {
        var activity = OutdoorActivity(activityType: .run, startedAt: Date(timeIntervalSince1970: 0))
        activity.appendPoint(point(lat: 37.0, lon: -122.0, at: Date(timeIntervalSince1970: 1)))
        activity.finish(at: Date(timeIntervalSince1970: 2))
        let revisionAfterFinish = activity.revision
        let distanceAfterFinish = activity.distanceMeters

        let accepted = activity.appendPoint(point(lat: 38.0, lon: -123.0, at: Date(timeIntervalSince1970: 3)))

        XCTAssertFalse(accepted)
        XCTAssertEqual(activity.routePoints.count, 1)
        XCTAssertEqual(activity.revision, revisionAfterFinish)
        XCTAssertEqual(activity.distanceMeters, distanceAfterFinish)
    }
}
