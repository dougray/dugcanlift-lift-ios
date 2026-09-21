import XCTest
@testable import Lift

/// `dugcanlift-lift-watch/shared/contracts/workout-sync.schema.json` is the
/// wire contract, and `PLAN_PUSHED` / `PLAN_REQUEST` / `SESSION_FINISHED`'s
/// heart rate are the newest part of it. These tests pin the JSON exactly as
/// `SyncEnvelopeTests` pins the rest, so the phone and the watch cannot drift
/// apart silently — the watch's `WorkoutPlanTests` asserts the same
/// spellings from the other end.
final class WatchPlanWireTests: XCTestCase {

    private func json(_ envelope: SyncEnvelope) throws -> [String: Any] {
        let data = try SyncEnvelope.encoder.encode(envelope)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func planEnvelope(_ plan: WorkoutPlan, revision: Int = 1) -> SyncEnvelope {
        SyncEnvelope(
            event: .planPushed,
            workoutID: UUID(uuidString: "6A2A8B6E-3D2F-4E77-9B4E-2C6A5E8C1D01")!,
            revision: revision,
            updatedAt: Date(timeIntervalSince1970: 0),
            origin: .ios,
            plan: plan
        )
    }

    private var fullPlan: WorkoutPlan {
        WorkoutPlan(
            name: "Upper A",
            source: .coachPlan,
            scheduledFor: "2026-09-20",
            exercises: [
                PlanExercise(
                    name: "Bench Press",
                    equipment: "barbell",
                    note: "Two second pause",
                    sets: [
                        PrescribedSet(weightKg: 83.9146, reps: 5, rpe: 8, restSeconds: 120),
                        PrescribedSet(weightKg: nil, reps: 5, rpe: nil, restSeconds: 120)
                    ],
                    lastPerformed: LastPerformed(
                        weightKg: 83.9146, reps: 5, rpe: 8, performedOn: "2026-09-13"
                    )
                )
            ]
        )
    }

    // MARK: - Key spellings

    func testPlanPushedEncodesContractFieldNames() throws {
        let object = try json(planEnvelope(fullPlan))

        XCTAssertEqual(object["event"] as? String, "PLAN_PUSHED")
        XCTAssertEqual(object["origin"] as? String, "ios")
        XCTAssertEqual(Set(object.keys), ["event", "workoutId", "revision", "updatedAt", "origin", "plan"])

        let plan = try XCTUnwrap(object["plan"] as? [String: Any])
        XCTAssertEqual(Set(plan.keys), ["name", "source", "scheduledFor", "exercises"])
        XCTAssertEqual(plan["name"] as? String, "Upper A")
        XCTAssertEqual(plan["source"] as? String, "COACH_PLAN")
        XCTAssertEqual(plan["scheduledFor"] as? String, "2026-09-20")

        let exercises = try XCTUnwrap(plan["exercises"] as? [[String: Any]])
        let exercise = try XCTUnwrap(exercises.first)
        XCTAssertEqual(Set(exercise.keys), ["name", "equipment", "note", "sets", "lastPerformed"])
        XCTAssertEqual(exercise["name"] as? String, "Bench Press")
        XCTAssertEqual(exercise["equipment"] as? String, "barbell")

        let sets = try XCTUnwrap(exercise["sets"] as? [[String: Any]])
        XCTAssertEqual(Set(sets[0].keys), ["weightKg", "reps", "rpe", "restSeconds"])
        XCTAssertEqual(sets[0]["reps"] as? Int, 5)
        XCTAssertEqual(sets[0]["rpe"] as? Double, 8)
        XCTAssertEqual(sets[0]["restSeconds"] as? Int, 120)

        let last = try XCTUnwrap(exercise["lastPerformed"] as? [String: Any])
        XCTAssertEqual(Set(last.keys), ["weightKg", "reps", "rpe", "performedOn"])
        XCTAssertEqual(last["performedOn"] as? String, "2026-09-13")
    }

    func testRoutineSourceSpelling() throws {
        let plan = WorkoutPlan(name: "Lower A", source: .routine, scheduledFor: nil, exercises: [])
        let object = try json(planEnvelope(plan))
        let encoded = try XCTUnwrap(object["plan"] as? [String: Any])
        XCTAssertEqual(encoded["source"] as? String, "ROUTINE")
    }

    func testPlanRequestSpelling() throws {
        let envelope = SyncEnvelope(
            event: .planRequest,
            workoutID: UUID(),
            revision: 1,
            updatedAt: Date(timeIntervalSince1970: 0),
            origin: .watchOS
        )
        let object = try json(envelope)
        XCTAssertEqual(object["event"] as? String, "PLAN_REQUEST")
        // A request is a bare envelope: no plan rides along with it.
        XCTAssertFalse(object.keys.contains("plan"))
    }

    // MARK: - Blank is absent, never zero

    func testBlankPrescriptionFieldsAreAbsentKeysNotZeros() throws {
        // PLAN-FORMAT's rule: `[null, 5]` is "five reps, you pick the
        // weight". On this wire that is a set carrying `reps` and nothing
        // else — not `"weightKg": 0`, and not `"weightKg": null`, either of
        // which an older or sloppier decoder would read as a real number.
        let plan = WorkoutPlan(
            name: "Upper A",
            source: .routine,
            scheduledFor: nil,
            exercises: [PlanExercise(name: "Chin Up", equipment: nil, note: nil,
                                     sets: [PrescribedSet(reps: 5)], lastPerformed: nil)]
        )
        let object = try json(planEnvelope(plan))
        let encoded = try XCTUnwrap(object["plan"] as? [String: Any])
        let exercise = try XCTUnwrap((encoded["exercises"] as? [[String: Any]])?.first)

        XCTAssertEqual(Set(exercise.keys), ["name", "sets"])
        let sets = try XCTUnwrap(exercise["sets"] as? [[String: Any]])
        XCTAssertEqual(Set(sets[0].keys), ["reps"])
        XCTAssertEqual(sets[0]["reps"] as? Int, 5)
    }

    func testEmptyPrescriptionIsAnEmptyObject() throws {
        let plan = WorkoutPlan(
            name: "Mobility",
            source: .routine,
            scheduledFor: nil,
            exercises: [PlanExercise(name: "Couch Stretch", equipment: nil, note: nil,
                                     sets: [PrescribedSet()], lastPerformed: nil)]
        )
        let object = try json(planEnvelope(plan))
        let encoded = try XCTUnwrap(object["plan"] as? [String: Any])
        let exercise = try XCTUnwrap((encoded["exercises"] as? [[String: Any]])?.first)
        let sets = try XCTUnwrap(exercise["sets"] as? [[String: Any]])
        XCTAssertTrue(sets[0].isEmpty)
    }

    func testExplicitNullPrescriptionFieldsDecodeAsNil() throws {
        // A future or third-party encoder might spell a blank as `null`
        // rather than omitting it. That must decode as "no prescription",
        // exactly as an absent key does — never as zero.
        let data = Data("""
        {"event":"PLAN_PUSHED","workoutId":"6A2A8B6E-3D2F-4E77-9B4E-2C6A5E8C1D01",
         "revision":1,"updatedAt":"1970-01-01T00:00:00Z","origin":"ios",
         "plan":{"name":"Upper A","source":"ROUTINE","exercises":[
           {"name":"Row","sets":[{"weightKg":null,"reps":8,"rpe":null,"restSeconds":null}]}]}}
        """.utf8)
        let decoded = try SyncEnvelope.decoder.decode(SyncEnvelope.self, from: data)
        let set = try XCTUnwrap(decoded.plan?.exercises.first?.sets.first)
        XCTAssertNil(set.weightKg)
        XCTAssertNil(set.rpe)
        XCTAssertNil(set.restSeconds)
        XCTAssertEqual(set.reps, 8)
    }

    // MARK: - Absence on other events

    func testNonPlanEventsOmitThePlanKeyEntirely() throws {
        let envelope = SyncEnvelope(
            event: .workoutEdited,
            workoutID: UUID(),
            revision: 4,
            updatedAt: Date(timeIntervalSince1970: 0),
            origin: .watchOS
        )
        let object = try json(envelope)
        XCTAssertEqual(Set(object.keys), ["event", "workoutId", "revision", "updatedAt", "origin"])
        XCTAssertFalse(object.keys.contains("plan"))
        XCTAssertFalse(object.keys.contains("heartRate"))
    }

    // MARK: - Heart rate

    func testSessionFinishedCarriesHeartRateUnderContractNames() throws {
        let envelope = SyncEnvelope(
            event: .sessionFinished,
            workoutID: UUID(),
            revision: 12,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            origin: .watchOS,
            heartRate: SessionHeartRate(averageBpm: 128.5, maxBpm: 171)
        )
        let object = try json(envelope)
        let heartRate = try XCTUnwrap(object["heartRate"] as? [String: Any])
        XCTAssertEqual(Set(heartRate.keys), ["averageBpm", "maxBpm"])
        XCTAssertEqual(heartRate["averageBpm"] as? Double, 128.5)
        XCTAssertEqual(heartRate["maxBpm"] as? Double, 171)

        let data = try SyncEnvelope.encoder.encode(envelope)
        XCTAssertEqual(try SyncEnvelope.decoder.decode(SyncEnvelope.self, from: data), envelope)
    }

    func testSessionFinishedWithoutHeartRateOmitsTheKey() throws {
        let envelope = SyncEnvelope(
            event: .sessionFinished,
            workoutID: UUID(),
            revision: 2,
            updatedAt: Date(timeIntervalSince1970: 0),
            origin: .watchOS
        )
        XCTAssertFalse(try json(envelope).keys.contains("heartRate"))
    }

    // MARK: - Round trip and tolerance

    func testPlanRoundTrips() throws {
        let envelope = planEnvelope(fullPlan, revision: 7)
        let data = try SyncEnvelope.encoder.encode(envelope)
        let decoded = try SyncEnvelope.decoder.decode(SyncEnvelope.self, from: data)
        XCTAssertEqual(decoded, envelope)
        XCTAssertEqual(decoded.plan?.exercises.first?.sets.count, 2)
        XCTAssertNil(decoded.plan?.exercises.first?.sets[1].weightKg)
    }

    func testUnknownEventIsRefusedSoAnOlderBuildIgnoresIt() throws {
        // The schema's compatibility rule, from this end: a build that does
        // not know an event fails to decode it, and every transport decodes
        // with `try?`, so the message is dropped rather than mishandled.
        let data = Data("""
        {"event":"SOMETHING_NEWER","workoutId":"6A2A8B6E-3D2F-4E77-9B4E-2C6A5E8C1D01",
         "revision":1,"updatedAt":"1970-01-01T00:00:00Z","origin":"watchOS"}
        """.utf8)
        XCTAssertThrowsError(try SyncEnvelope.decoder.decode(SyncEnvelope.self, from: data))
        XCTAssertNil(try? SyncEnvelope(messageBody: [
            "event": "SOMETHING_NEWER",
            "workoutId": "6A2A8B6E-3D2F-4E77-9B4E-2C6A5E8C1D01",
            "revision": 1,
            "updatedAt": "1970-01-01T00:00:00Z",
            "origin": "watchOS"
        ]))
    }

    func testUnknownPlanFieldsAreTolerated() throws {
        let data = Data("""
        {"event":"PLAN_PUSHED","workoutId":"6A2A8B6E-3D2F-4E77-9B4E-2C6A5E8C1D01",
         "revision":1,"updatedAt":"1970-01-01T00:00:00Z","origin":"ios","futureField":true,
         "plan":{"name":"Upper A","source":"ROUTINE","futureField":1,"exercises":[
           {"name":"Row","sets":[{"reps":8,"tempo":"3010"}],"superset":2}]}}
        """.utf8)
        let decoded = try SyncEnvelope.decoder.decode(SyncEnvelope.self, from: data)
        XCTAssertEqual(decoded.plan?.name, "Upper A")
        XCTAssertEqual(decoded.plan?.exercises.first?.sets.first?.reps, 8)
    }
}
