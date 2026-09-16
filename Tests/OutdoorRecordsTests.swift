import XCTest
import LiftCore
@testable import Lift

final class OutdoorRecordsTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func activity(_ type: OutdoorActivityType, dayOffset: Int = 0,
                          meters: Double, seconds: TimeInterval?, points: Int = 2) -> OutdoorActivity {
        let start = t0.addingTimeInterval(TimeInterval(dayOffset) * 86_400)
        let activity = OutdoorActivity(activityType: type, startedAt: start)
        activity.distanceMeters = meters
        if let seconds { activity.endedAt = start.addingTimeInterval(seconds) }
        activity.routePoints = (0..<points).map {
            RoutePoint(latitude: 30 + Double($0) * 0.001, longitude: -97, altitudeMeters: 150,
                       recordedAt: start, horizontalAccuracyMeters: 5, verticalAccuracyMeters: 5)
        }
        return activity
    }

    // MARK: - Last route

    func testTheLastRouteIsTheNewestFinishedOne() {
        let older = activity(.run, dayOffset: 0, meters: 5_000, seconds: 1_500)
        let newer = activity(.hike, dayOffset: 2, meters: 8_000, seconds: 7_200)
        XCTAssertTrue(OutdoorRecords.lastRoute(in: [newer, older]) === newer)
        XCTAssertTrue(OutdoorRecords.lastRoute(in: [older, newer]) === newer, "order of the input does not matter")
    }

    func testARecordingStillInProgressIsNotTheLastRoute() {
        let finished = activity(.run, dayOffset: 0, meters: 5_000, seconds: 1_500)
        let recording = activity(.walk, dayOffset: 1, meters: 900, seconds: nil)
        XCTAssertTrue(OutdoorRecords.lastRoute(in: [finished, recording]) === finished)
    }

    func testAnActivityWithOneFixHasNoLineToDraw() {
        let drawable = activity(.run, dayOffset: 0, meters: 5_000, seconds: 1_500)
        let oneFix = activity(.run, dayOffset: 1, meters: 0, seconds: 60, points: 1)
        XCTAssertTrue(OutdoorRecords.lastRoute(in: [drawable, oneFix]) === drawable)
        XCTAssertNil(OutdoorRecords.lastRoute(in: [oneFix]))
    }

    // MARK: - Bests

    func testBestsArePerTypeInStartButtonOrder() {
        let bests = OutdoorRecords.bests(in: [
            activity(.hike, meters: 9_000, seconds: 10_000),
            activity(.run, meters: 5_000, seconds: 1_500),
        ])
        XCTAssertEqual(bests.map(\.type), [.run, .hike], "walk has nothing, so it has no row")
    }

    func testFarthestAndLongestCanComeFromDifferentActivities() throws {
        let run = try XCTUnwrap(OutdoorRecords.bests(in: [
            activity(.run, meters: 10_000, seconds: 3_000),
            activity(.run, meters: 6_000, seconds: 3_600),
        ]).first)
        XCTAssertEqual(run.count, 2)
        XCTAssertEqual(run.longestDistanceMeters, 10_000)
        XCTAssertEqual(run.longestDuration, 3_600)
        XCTAssertEqual(try XCTUnwrap(run.fastestPaceSecondsPerMeter), 0.3, accuracy: 1e-9)
    }

    func testAShortBlipCannotSetTheFastestPace() throws {
        // 40 m in 5 s is 3:21 a mile. It is GPS drift, not a record.
        let run = try XCTUnwrap(OutdoorRecords.bests(in: [
            activity(.run, meters: 5_000, seconds: 1_500),
            activity(.run, meters: 40, seconds: 5),
        ]).first)
        XCTAssertEqual(try XCTUnwrap(run.fastestPaceSecondsPerMeter), 0.3, accuracy: 1e-9)
    }

    func testNoPaceUntilOneRecordingIsLongEnough() throws {
        let walk = try XCTUnwrap(OutdoorRecords.bests(in: [activity(.walk, meters: 800, seconds: 600)]).first)
        XCTAssertNil(walk.fastestPaceSecondsPerMeter)
        XCTAssertEqual(walk.longestDistanceMeters, 800)
    }

    func testAnUnfinishedRecordingCountsForNothing() {
        XCTAssertTrue(OutdoorRecords.bests(in: [activity(.run, meters: 42_000, seconds: nil)]).isEmpty)
    }

    func testBlankStaysBlank() throws {
        // Finished with no distance at all — GPS never locked. No farthest of 0.
        let hike = try XCTUnwrap(OutdoorRecords.bests(in: [activity(.hike, meters: 0, seconds: 900, points: 0)]).first)
        XCTAssertNil(hike.longestDistanceMeters)
        XCTAssertEqual(hike.longestDuration, 900)
    }

    // MARK: - Formatting

    func testDurationText() {
        XCTAssertEqual(OutdoorRecords.durationText(1_720), "28:40")
        XCTAssertEqual(OutdoorRecords.durationText(3_730), "1:02:10")
    }

    func testPaceTextInBothUnits() {
        // 0.3 s/m is 8:03 a mile and 5:00 a kilometre.
        XCTAssertEqual(OutdoorRecords.paceText(0.3, unit: .miles), "8:03 /mi")
        XCTAssertEqual(OutdoorRecords.paceText(0.3, unit: .kilometers), "5:00 /km")
    }

    func testWalkIsStoredAndReadBackByName() {
        XCTAssertEqual(OutdoorActivityType(rawValue: "walk"), .walk)
        XCTAssertEqual(OutdoorActivityType.walk.displayName, "Walk")
    }
}
