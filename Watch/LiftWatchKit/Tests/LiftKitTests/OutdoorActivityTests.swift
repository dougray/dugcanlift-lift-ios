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

    // MARK: - healthKitUUID / markExported(_:)
    //
    // The actual `HKWorkoutBuilder` call this field's idempotency guards
    // lives in `apple/LiftWatch/HealthKitExporter.swift` and needs the
    // Watch Simulator or a device — not testable here. What belongs in this
    // package is `OutdoorActivity`'s own state machine around the field:
    // it defaults to `nil`, `markExported(_:)` sets it exactly once, and —
    // since `OutdoorActivity`'s `Codable` conformance is synthesized rather
    // than a custom `init(from:)` — an encoded value from before this field
    // existed still decodes with `healthKitUUID == nil` rather than failing.

    func testFreshActivityHasNilHealthKitUUID() {
        let activity = OutdoorActivity(activityType: .run, startedAt: Date(timeIntervalSince1970: 0))
        XCTAssertNil(activity.healthKitUUID)
    }

    func testMarkExportedSetsHealthKitUUIDAndBumpsRevision() {
        var activity = OutdoorActivity(activityType: .run, startedAt: Date(timeIntervalSince1970: 0))
        activity.finish(at: Date(timeIntervalSince1970: 10))
        let revisionBeforeExport = activity.revision
        let uuid = UUID()

        let accepted = activity.markExported(uuid, at: Date(timeIntervalSince1970: 20))

        XCTAssertTrue(accepted)
        XCTAssertEqual(activity.healthKitUUID, uuid)
        XCTAssertEqual(activity.updatedAt, Date(timeIntervalSince1970: 20))
        XCTAssertEqual(activity.revision, revisionBeforeExport + 1)
    }

    func testMarkExportedTwiceIsANoOp() {
        var activity = OutdoorActivity(activityType: .run, startedAt: Date(timeIntervalSince1970: 0))
        let firstUUID = UUID()
        XCTAssertTrue(activity.markExported(firstUUID, at: Date(timeIntervalSince1970: 10)))
        let revisionAfterFirstExport = activity.revision

        let accepted = activity.markExported(UUID(), at: Date(timeIntervalSince1970: 20))

        XCTAssertFalse(accepted)
        XCTAssertEqual(activity.healthKitUUID, firstUUID)
        XCTAssertEqual(activity.revision, revisionAfterFirstExport)
    }

    /// The concrete backward-compatibility guarantee: JSON encoded before
    /// `healthKitUUID` existed — the key is entirely absent, not present
    /// with a null value — still decodes successfully, with the field
    /// defaulting to `nil` rather than throwing `keyNotFound`.
    func testDecodingOldFormatJSONWithoutHealthKitUUIDKeyDefaultsToNil() throws {
        // healthKitUUID is set here (not left nil) so the encoded JSON
        // actually contains the key — proving the test genuinely simulates
        // stripping a *present* key, rather than trivially passing because
        // Codable's synthesized encoder already omits nil Optionals.
        let activity = OutdoorActivity(
            activityType: .hike,
            startedAt: Date(timeIntervalSince1970: 0),
            endedAt: Date(timeIntervalSince1970: 100),
            healthKitUUID: UUID()
        )
        let encoded = try JSONEncoder().encode(activity)

        var json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        XCTAssertNotNil(json["healthKitUUID"], "precondition: the field is normally present")
        json.removeValue(forKey: "healthKitUUID")
        let oldFormatData = try JSONSerialization.data(withJSONObject: json)

        let decoded = try JSONDecoder().decode(OutdoorActivity.self, from: oldFormatData)

        XCTAssertNil(decoded.healthKitUUID)
        XCTAssertEqual(decoded.id, activity.id)
        XCTAssertEqual(decoded.activityType, activity.activityType)
        XCTAssertEqual(decoded.endedAt, activity.endedAt)
    }
}
