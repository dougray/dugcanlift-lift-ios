import XCTest
@testable import LiftKit

/// Ported from `lift-ios`'s `Tests/OutdoorActivityCalculationsTests.swift` —
/// same cases, adapted to LiftKit's public `RoutePoint`/`OutdoorActivityMath`.
final class OutdoorActivityMathTests: XCTestCase {

    func testDistanceOfASingleKnownSegment() {
        // Austin, TX: two points ~111m apart (roughly 0.001 degrees latitude
        // at this longitude) — a known, checkable real-world distance.
        let points = [
            RoutePoint(latitude: 30.2672, longitude: -97.7431, altitudeMeters: 150, recordedAt: .now, horizontalAccuracyMeters: 5.0, verticalAccuracyMeters: 5.0),
            RoutePoint(latitude: 30.2682, longitude: -97.7431, altitudeMeters: 150, recordedAt: .now, horizontalAccuracyMeters: 5.0, verticalAccuracyMeters: 5.0)
        ]
        let distance = OutdoorActivityMath.totalDistanceMeters(points)
        XCTAssertEqual(distance, 111.2, accuracy: 1.0)
    }

    func testDistanceOfEmptyOrSinglePointIsZero() {
        XCTAssertEqual(OutdoorActivityMath.totalDistanceMeters([]), 0)
        XCTAssertEqual(OutdoorActivityMath.totalDistanceMeters([
            RoutePoint(latitude: 0, longitude: 0, altitudeMeters: 0, recordedAt: .now, horizontalAccuracyMeters: 5.0, verticalAccuracyMeters: 5.0)
        ]), 0)
    }

    func testDistanceSumsMultipleSegments() {
        let points = (0...3).map { i in
            RoutePoint(latitude: 30.2672 + Double(i) * 0.001, longitude: -97.7431,
                      altitudeMeters: 150, recordedAt: .now, horizontalAccuracyMeters: 5.0, verticalAccuracyMeters: 5.0)
        }
        let distance = OutdoorActivityMath.totalDistanceMeters(points)
        XCTAssertEqual(distance, 111.2 * 3, accuracy: 3.0)
    }

    func testElevationGainIgnoresNoiseBelowThreshold() {
        // Jitters of 1-2m (below the 3m default threshold) must not count.
        let points = [
            RoutePoint(latitude: 0, longitude: 0, altitudeMeters: 100, recordedAt: .now, horizontalAccuracyMeters: 5.0, verticalAccuracyMeters: 5.0),
            RoutePoint(latitude: 0, longitude: 0, altitudeMeters: 101.5, recordedAt: .now, horizontalAccuracyMeters: 5.0, verticalAccuracyMeters: 5.0),
            RoutePoint(latitude: 0, longitude: 0, altitudeMeters: 100.2, recordedAt: .now, horizontalAccuracyMeters: 5.0, verticalAccuracyMeters: 5.0),
            RoutePoint(latitude: 0, longitude: 0, altitudeMeters: 101.8, recordedAt: .now, horizontalAccuracyMeters: 5.0, verticalAccuracyMeters: 5.0)
        ]
        XCTAssertEqual(OutdoorActivityMath.elevationGainMeters(points), 0)
    }

    func testElevationGainCountsRealClimbs() {
        // A genuine climb of 10m, then a genuine descent, then another climb
        // of 5m — only the two climbs count, totaling 15m.
        let points = [
            RoutePoint(latitude: 0, longitude: 0, altitudeMeters: 100, recordedAt: .now, horizontalAccuracyMeters: 5.0, verticalAccuracyMeters: 5.0),
            RoutePoint(latitude: 0, longitude: 0, altitudeMeters: 110, recordedAt: .now, horizontalAccuracyMeters: 5.0, verticalAccuracyMeters: 5.0), // +10
            RoutePoint(latitude: 0, longitude: 0, altitudeMeters: 102, recordedAt: .now, horizontalAccuracyMeters: 5.0, verticalAccuracyMeters: 5.0), // -8, not counted as gain
            RoutePoint(latitude: 0, longitude: 0, altitudeMeters: 107, recordedAt: .now, horizontalAccuracyMeters: 5.0, verticalAccuracyMeters: 5.0)  // +5
        ]
        XCTAssertEqual(OutdoorActivityMath.elevationGainMeters(points), 15, accuracy: 0.01)
    }

    func testElevationGainOfFlatRouteIsZero() {
        let points = (0..<10).map { _ in
            RoutePoint(latitude: 0, longitude: 0, altitudeMeters: 200, recordedAt: .now, horizontalAccuracyMeters: 5.0, verticalAccuracyMeters: 5.0)
        }
        XCTAssertEqual(OutdoorActivityMath.elevationGainMeters(points), 0)
    }

    func testCustomThresholdIsRespected() {
        let points = [
            RoutePoint(latitude: 0, longitude: 0, altitudeMeters: 100, recordedAt: .now, horizontalAccuracyMeters: 5.0, verticalAccuracyMeters: 5.0),
            RoutePoint(latitude: 0, longitude: 0, altitudeMeters: 101, recordedAt: .now, horizontalAccuracyMeters: 5.0, verticalAccuracyMeters: 5.0)
        ]
        XCTAssertEqual(OutdoorActivityMath.elevationGainMeters(points, minimumDeltaMeters: 0.5), 1, accuracy: 0.01)
        XCTAssertEqual(OutdoorActivityMath.elevationGainMeters(points, minimumDeltaMeters: 3.0), 0)
    }
}
