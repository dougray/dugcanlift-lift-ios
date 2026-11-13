import XCTest
@testable import Lift

final class LiveRunStatsTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func point(lat: Double, at: Date) -> RoutePoint {
        RoutePoint(latitude: lat, longitude: 0, altitudeMeters: 0, recordedAt: at,
                   horizontalAccuracyMeters: 5, verticalAccuracyMeters: 5)
    }

    func testNothingRecordedYet() {
        let stats = LiveRunStats.compute(points: [], startedAt: start, now: start)
        XCTAssertEqual(stats.elapsed, 0)
        XCTAssertEqual(stats.distanceMeters, 0)
        XCTAssertNil(stats.paceSecondsPerMeter)
    }

    func testANowBeforeTheStartIsZeroNotNegative() {
        let stats = LiveRunStats.compute(points: [], startedAt: start, now: start.addingTimeInterval(-5))
        XCTAssertEqual(stats.elapsed, 0)
    }

    func testPaceIsElapsedOverDistance() {
        // 1000 m of latitude on the haversine sphere (R = 6,371,000 m).
        let degrees = 1000.0 / 6_371_000.0 * 180 / .pi
        let points = [point(lat: 0, at: start), point(lat: degrees, at: start.addingTimeInterval(300))]
        let stats = LiveRunStats.compute(points: points, startedAt: start, now: start.addingTimeInterval(300))
        XCTAssertEqual(stats.elapsed, 300)
        XCTAssertEqual(stats.distanceMeters, 1000, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(stats.paceSecondsPerMeter), 0.3, accuracy: 0.001)
    }

    func testNoPaceUnderTenMeters() {
        let degrees = 9.0 / 6_371_000.0 * 180 / .pi
        let points = [point(lat: 0, at: start), point(lat: degrees, at: start.addingTimeInterval(30))]
        let stats = LiveRunStats.compute(points: points, startedAt: start, now: start.addingTimeInterval(60))
        XCTAssertNil(stats.paceSecondsPerMeter)
        XCTAssertEqual(stats.paceText(unit: .miles), "--")
    }

    func testTheTextBothScreensShare() {
        let stats = LiveRunStats(elapsed: 3_725, distanceMeters: 1609.344, paceSecondsPerMeter: 0.3)
        XCTAssertEqual(stats.elapsedText, "01:02:05")
        XCTAssertEqual(stats.distanceText(unit: .miles), "1.00 mi")
        XCTAssertEqual(stats.paceText(unit: .miles), "8:03 /mi")
    }
}
