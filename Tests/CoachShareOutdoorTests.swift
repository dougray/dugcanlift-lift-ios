import XCTest
import SwiftData
import LiftCore
@testable import Lift

/// Runs, walks and hikes in a Send to Coach link — SHARE-FORMAT.md "Outdoor".
///
/// `outdoor-share-input.json` and `outdoor-share-expected.json` were written by
/// LIFT web and copied here unchanged. Never regenerate them from this app:
/// agreement with this encoder alone proves nothing about what a coach reads.
final class CoachShareOutdoorTests: XCTestCase {

    private func makeContext() -> ModelContext {
        ModelContext(LiftStore.makeContainer(inMemory: true))
    }

    private func fixture(_ name: String) throws -> [String: Any] {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "json"),
                                "fixture \(name).json is not in the test bundle")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    /// The fixture's `outdoor[]`, stored the way the recorder stores it. The
    /// unfinished hike keeps its nil end, exactly as an activity still being
    /// recorded would, so skipping it is the encoder's job and not this map's.
    /// `shift` moves every start and end by the same amount, for tests that
    /// need the activities inside the send window.
    private func activities(_ context: ModelContext, shift: TimeInterval = 0) throws -> [OutdoorActivity] {
        let rows = try XCTUnwrap(fixture("outdoor-share-input")["outdoor"] as? [[String: Any]])
        return try rows.map { row in
            let raw = try XCTUnwrap(row["activityType"] as? String).lowercased()
            let type = try XCTUnwrap(OutdoorActivityType(rawValue: raw))
            let started = try XCTUnwrap(row["startedAtEpochMs"] as? Double)
            let activity = OutdoorActivity(activityType: type,
                                           startedAt: Date(timeIntervalSince1970: started / 1000 + shift))
            if let ended = row["endedAtEpochMs"] as? Double {
                activity.endedAt = Date(timeIntervalSince1970: ended / 1000 + shift)
            }
            activity.distanceMeters = try XCTUnwrap(row["distanceMeters"] as? Double)
            activity.elevationGainMeters = try XCTUnwrap(row["elevationGainMeters"] as? Double)
            let points = row["routePoints"] as? [[String: Any]] ?? []
            activity.routePoints = try points.map { point in
                RoutePoint(latitude: try XCTUnwrap(point["latitude"] as? Double),
                           longitude: try XCTUnwrap(point["longitude"] as? Double),
                           altitudeMeters: point["altitudeMeters"] as? Double ?? 0,
                           recordedAt: Date(timeIntervalSince1970: (point["recordedAtEpochMs"] as? Double ?? 0) / 1000),
                           horizontalAccuracyMeters: point["horizontalAccuracyMeters"] as? Double ?? 0,
                           verticalAccuracyMeters: 0)
            }
            context.insert(activity)
            return activity
        }
    }

    /// Serialized with sorted keys, so two values compare as bytes rather
    /// than through `NSNumber` equality, which would let 1 equal `true`.
    private func json(_ value: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed])
        return String(decoding: data, as: UTF8.self)
    }

    private func snapshot(outdoor: [OutdoorActivity], days: [WorkoutDay] = [],
                          measurements: [BodyMeasurement] = []) -> CoachShare.Snapshot {
        CoachShare.Snapshot(days: days, food: [], measurements: measurements,
                            outdoor: outdoor, goal: nil, unit: .pounds)
    }

    // MARK: - Against LIFT web's fixture

    func testOutdoorPartsMatchLiftWeb() throws {
        let context = makeContext()
        let all = try activities(context)
        let expected = try fixture("outdoor-share-expected")

        XCTAssertEqual(try json(CoachShare.outdoorDay(all)), try json(try XCTUnwrap(expected["o"])))
        XCTAssertEqual(try json(try XCTUnwrap(CoachShare.outdoorBests(all))),
                       try json(try XCTUnwrap(expected["ob"])))

        let route = try XCTUnwrap(CoachShare.outdoorLastRoute(all) as? [Any])
        let expectedRoute = try XCTUnwrap(expected["lr"] as? [Any])
        XCTAssertEqual(try json(route), try json(expectedRoute))
        // Said separately so a failure names the polyline, not a wall of JSON.
        XCTAssertEqual(route.last as? String, expectedRoute.last as? String)
    }

    // MARK: - In the payload

    /// The fixture moved so its newest finished run started two days ago,
    /// which puts every finished activity inside a four-week window.
    private func recentActivities(_ context: ModelContext) throws -> [OutdoorActivity] {
        let newestStart = 1_789_259_200.0
        let twoDaysAgo = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: -2, to: .now))
        return try activities(context, shift: twoDaysAgo.timeIntervalSince1970.rounded(.down) - newestStart)
    }

    func testOptedInSendsDaysBestsAndRoute() throws {
        let context = makeContext()
        let all = try recentActivities(context)
        let payload = CoachShare.buildPayload(from: snapshot(outdoor: all), weeks: 4,
                                              itemised: false, lastRoute: true)
        let expected = try fixture("outdoor-share-expected")

        // No workouts, food, steps or weights: every day here is outdoor-only,
        // and each must still be sent.
        let days = try XCTUnwrap(payload["d"] as? [[String: Any]])
        XCTAssertFalse(days.isEmpty)
        let sent = days.flatMap { $0["o"] as? [Any] ?? [] }
        XCTAssertEqual(days.filter { $0["o"] == nil }.count, 0)
        XCTAssertEqual(try json(sent), try json(try XCTUnwrap(expected["o"])))
        XCTAssertEqual(try json(try XCTUnwrap(payload["ob"])), try json(try XCTUnwrap(expected["ob"])))

        let route = try XCTUnwrap(payload["lr"] as? [Any])
        XCTAssertEqual(route.last as? String, (expected["lr"] as? [Any])?.last as? String)
    }

    func testRouteStaysHomeUnlessOptedIn() throws {
        let context = makeContext()
        let all = try recentActivities(context)
        let payload = CoachShare.buildPayload(from: snapshot(outdoor: all), weeks: 4,
                                              itemised: false, lastRoute: false)

        XCTAssertNil(payload["lr"])
        XCTAssertNotNil(payload["ob"])
        let days = try XCTUnwrap(payload["d"] as? [[String: Any]])
        XCTAssertTrue(days.contains { $0["o"] != nil })
    }

    func testAnOutdoorOnlyDayIsADay() throws {
        let context = makeContext()
        let walk = OutdoorActivity(activityType: .walk,
                                   startedAt: try XCTUnwrap(Calendar.current.date(byAdding: .day, value: -1, to: .now)))
        walk.endedAt = walk.startedAt.addingTimeInterval(1_200)
        walk.distanceMeters = 1_500
        context.insert(walk)

        let payload = CoachShare.buildPayload(from: snapshot(outdoor: [walk]), weeks: 4,
                                              itemised: false, lastRoute: false)
        let days = try XCTUnwrap(payload["d"] as? [[String: Any]])
        XCTAssertEqual(days.count, 1)
        XCTAssertEqual(try json(try XCTUnwrap(days.first?["o"])), "[[1,1200,1500,0]]")
    }

    /// Nothing outdoor, or only something still recording, must leave the
    /// payload exactly as it was before outdoor existed — whichever way the
    /// route setting points.
    func testNoOutdoorLeavesThePayloadAlone() throws {
        let context = makeContext()
        let day = WorkoutDay(date: .now, name: "Push A", focus: .bodybuilding)
        let exercise = ExerciseEntry(exerciseRefID: "x", name: "Back Squat", orderIndex: 0)
        exercise.sets = [SetEntry(orderIndex: 0, weightKg: 100, reps: 5)]
        day.exercises = [exercise]
        context.insert(day)
        let weight = BodyMeasurement(weightKg: 90)
        context.insert(weight)

        let unfinished = OutdoorActivity(activityType: .hike, startedAt: .now)
        unfinished.distanceMeters = 900
        context.insert(unfinished)

        func build(_ outdoor: [OutdoorActivity], lastRoute: Bool) throws -> String {
            var payload = CoachShare.buildPayload(
                from: snapshot(outdoor: outdoor, days: [day], measurements: [weight]),
                weeks: 4, itemised: false, lastRoute: lastRoute)
            // The only field that reads the clock at second resolution.
            payload["z"] = nil
            return try json(payload)
        }

        let before = try build([], lastRoute: false)
        XCTAssertFalse(before.contains("\"o\""))
        XCTAssertFalse(before.contains("\"ob\""))
        XCTAssertFalse(before.contains("\"lr\""))
        XCTAssertEqual(try build([], lastRoute: true), before)
        XCTAssertEqual(try build([unfinished], lastRoute: true), before)
        XCTAssertEqual(try build([unfinished], lastRoute: false), before)
    }
}
