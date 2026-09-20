import XCTest
import SwiftData
@testable import Lift

final class OutdoorActivityModelsTests: XCTestCase {

    /// `LiftStore.schema`, never a version pinned by hand — a pinned one
    /// stops being the app's schema the moment a new version lands, and the
    /// failure is a cast inside SwiftData rather than a compile error.
    private func makeContext() throws -> ModelContext {
        ModelContext(LiftStore.makeContainer(inMemory: true))
    }

    func testRoutePointsRoundTripThroughStorage() throws {
        let context = try makeContext()
        let activity = OutdoorActivity(activityType: .run, startedAt: .now)
        let points = [
            RoutePoint(latitude: 30.2672, longitude: -97.7431, altitudeMeters: 149, recordedAt: .now, horizontalAccuracyMeters: 5.0, verticalAccuracyMeters: 5.0),
            RoutePoint(latitude: 30.2675, longitude: -97.7429, altitudeMeters: 151, recordedAt: .now, horizontalAccuracyMeters: 5.0, verticalAccuracyMeters: 5.0)
        ]
        activity.routePoints = points
        context.insert(activity)
        try context.save()

        let fetched = try XCTUnwrap(context.fetch(FetchDescriptor<OutdoorActivity>()).first)
        XCTAssertEqual(fetched.routePoints, points)
    }

    func testDurationIsNilUntilEnded() {
        let activity = OutdoorActivity(activityType: .hike, startedAt: .now)
        XCTAssertNil(activity.duration)
    }

    func testDurationOnceEnded() {
        let start = Date(timeIntervalSince1970: 1_000)
        let activity = OutdoorActivity(activityType: .run, startedAt: start)
        activity.endedAt = Date(timeIntervalSince1970: 1_600)
        XCTAssertEqual(activity.duration, 600)
    }

    func testAveragePaceIsNilWithNoDistance() {
        let activity = OutdoorActivity(activityType: .run, startedAt: .now)
        activity.endedAt = activity.startedAt.addingTimeInterval(600)
        activity.distanceMeters = 0
        XCTAssertNil(activity.averagePaceSecondsPerMeter)
    }

    func testAveragePaceCalculation() {
        let activity = OutdoorActivity(activityType: .run, startedAt: .now)
        activity.endedAt = activity.startedAt.addingTimeInterval(1200) // 20 min
        activity.distanceMeters = 4000 // 4 km
        XCTAssertEqual(activity.averagePaceSecondsPerMeter ?? 0, 0.3, accuracy: 0.0001) // 300s/km
    }
}
