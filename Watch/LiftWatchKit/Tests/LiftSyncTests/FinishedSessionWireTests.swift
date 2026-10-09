import XCTest
import LiftSync

/// `SESSION_FINISHED` carries the whole workout that was logged, and these
/// pin the JSON it carries it in, exactly as `WatchPlanWireTests` pins
/// `PLAN_PUSHED`'s. A phone and a watch can run different builds, so the
/// field names and the absent-key rules are a contract, not an
/// implementation detail. `SchemaConformanceTests` checks the same types
/// against `Watch/contracts/workout-sync.schema.json` itself.
final class FinishedSessionWireTests: XCTestCase {

    private let sessionID = UUID(uuidString: "6A2A8B6E-3D2F-4E77-9B4E-2C6A5E8C1D01")!

    private func json(_ envelope: SyncEnvelope) throws -> [String: Any] {
        let data = try SyncEnvelope.encoder.encode(envelope)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func envelope(_ session: FinishedSession, revision: Int = 2) -> SyncEnvelope {
        SyncEnvelope(
            event: .sessionFinished,
            workoutID: sessionID,
            revision: revision,
            updatedAt: Date(timeIntervalSince1970: 1_789_894_800),
            origin: .watchOS,
            session: session
        )
    }

    private var fullSession: FinishedSession {
        FinishedSession(
            name: "Upper A",
            focus: "bodybuilding",
            performedOn: "2026-09-20",
            startedAt: Date(timeIntervalSince1970: 1_789_891_200),
            finishedAt: Date(timeIntervalSince1970: 1_789_894_800),
            exercises: [
                PerformedExercise(
                    name: "Bench Press",
                    equipment: "barbell",
                    sets: [
                        PerformedSet(weightKg: 60, reps: 8, isWarmup: true,
                                     completedAt: Date(timeIntervalSince1970: 1_789_891_500)),
                        PerformedSet(weightKg: 83.9146, reps: 5, rpe: 8,
                                     completedAt: Date(timeIntervalSince1970: 1_789_892_000))
                    ]
                ),
                PerformedExercise(
                    name: "Bulgarian Split Squat",
                    equipment: "dumbbell",
                    sets: [
                        PerformedSet(weightKg: 30, reps: 8, rpe: 8, side: .left),
                        PerformedSet(weightKg: 30, reps: 7, rpe: 9, side: .right)
                    ]
                )
            ]
        )
    }

    // MARK: - Key spellings

    func testSessionFinishedEncodesContractFieldNames() throws {
        let object = try json(envelope(fullSession))

        XCTAssertEqual(object["event"] as? String, "SESSION_FINISHED")
        XCTAssertEqual(object["origin"] as? String, "watchOS")
        XCTAssertEqual(Set(object.keys),
                       ["event", "workoutId", "revision", "updatedAt", "origin", "session"])

        let session = try XCTUnwrap(object["session"] as? [String: Any])
        XCTAssertEqual(Set(session.keys),
                       ["name", "focus", "performedOn", "startedAt", "finishedAt", "exercises"])
        XCTAssertEqual(session["performedOn"] as? String, "2026-09-20")
        XCTAssertEqual(session["startedAt"] as? String, "2026-09-20T08:00:00Z")

        let exercises = try XCTUnwrap(session["exercises"] as? [[String: Any]])
        XCTAssertEqual(exercises.map { $0["name"] as? String },
                       ["Bench Press", "Bulgarian Split Squat"])

        let warmup = try XCTUnwrap((exercises[0]["sets"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(warmup.keys), ["weightKg", "reps", "warmup", "completedAt"])
        XCTAssertEqual(warmup["warmup"] as? Bool, true)

        let left = try XCTUnwrap((exercises[1]["sets"] as? [[String: Any]])?.first)
        XCTAssertEqual(left["side"] as? String, "left")
        XCTAssertEqual(left["weightKg"] as? Double, 30)
        XCTAssertEqual(left["reps"] as? Int, 8)
        XCTAssertEqual(left["rpe"] as? Double, 8)
    }

    /// The whole point of the payload: what was lifted, on which limb,
    /// survives a round trip through the wire untouched.
    func testASessionSurvivesTheRoundTripBothWays() throws {
        let sent = envelope(fullSession)

        let body = try sent.messageBody()
        let received = try SyncEnvelope(messageBody: body)

        XCTAssertEqual(received, sent)
        XCTAssertEqual(received.session?.exercises[1].sets.map(\.side), [.left, .right])
        XCTAssertEqual(received.session?.exercises[0].sets.map(\.isWarmup), [true, false])
        XCTAssertEqual(received.session?.exercises[0].sets[1].weightKg, 83.9146)
        XCTAssertEqual(try received.messageBody() as NSDictionary, body as NSDictionary)
    }

    // MARK: - Absent keys, never nulls

    /// A session with no sides, no warmups, no RPE and no focus writes none
    /// of those keys: a receiver that predates any of them reads exactly the
    /// document it always read.
    func testNothingOptionalIsWrittenWhenItSaysNothing() throws {
        let plain = FinishedSession(
            name: "Workout",
            performedOn: "2026-09-20",
            startedAt: Date(timeIntervalSince1970: 1_789_891_200),
            finishedAt: Date(timeIntervalSince1970: 1_789_894_800),
            exercises: [PerformedExercise(name: "Deadlift",
                                          sets: [PerformedSet(weightKg: 140, reps: 3)])]
        )

        let object = try json(envelope(plain))
        let session = try XCTUnwrap(object["session"] as? [String: Any])
        XCTAssertEqual(Set(session.keys),
                       ["name", "performedOn", "startedAt", "finishedAt", "exercises"])

        let exercise = try XCTUnwrap((session["exercises"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(exercise.keys), ["name", "sets"])

        let set = try XCTUnwrap((exercise["sets"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(set.keys), ["weightKg", "reps"])
    }

    /// Zero is a real recorded value on a performed set — a bodyweight
    /// dip is 0 kg — and must not be confused with the prescription rule
    /// that a blank is never a zero.
    func testAZeroWeightIsAValueAndIsWritten() throws {
        let bodyweight = FinishedSession(
            name: "Dips", performedOn: "2026-09-20",
            startedAt: Date(timeIntervalSince1970: 1_789_891_200),
            finishedAt: Date(timeIntervalSince1970: 1_789_894_800),
            exercises: [PerformedExercise(name: "Dip",
                                          sets: [PerformedSet(weightKg: 0, reps: 12)])]
        )

        let object = try json(envelope(bodyweight))
        let set = try XCTUnwrap((((object["session"] as? [String: Any])?["exercises"]
            as? [[String: Any]])?.first?["sets"] as? [[String: Any]])?.first)
        XCTAssertEqual(set["weightKg"] as? Double, 0)
        XCTAssertEqual(try SyncEnvelope(messageBody: object).session?
            .exercises[0].sets[0].weightKg, 0)
    }

    // MARK: - Reading what a later build might send

    /// A session is the only copy of somebody's work, so a word this build
    /// does not know costs the side and nothing else.
    func testAnUnknownSideReadsAsTwoSidedRatherThanFailing() throws {
        var body = try envelope(fullSession).messageBody()
        var session = try XCTUnwrap(body["session"] as? [String: Any])
        var exercises = try XCTUnwrap(session["exercises"] as? [[String: Any]])
        var sets = try XCTUnwrap(exercises[1]["sets"] as? [[String: Any]])
        sets[0]["side"] = "dominant"
        exercises[1]["sets"] = sets
        session["exercises"] = exercises
        body["session"] = session

        let received = try SyncEnvelope(messageBody: body)

        XCTAssertNil(received.session?.exercises[1].sets[0].side)
        XCTAssertEqual(received.session?.exercises[1].sets[0].reps, 8)
        XCTAssertEqual(received.session?.exercises[1].sets[1].side, .right)
    }

    /// A key a later build adds is ignored, not fatal — the schema's
    /// `additionalProperties: true`, exercised.
    func testAKeyThisBuildDoesNotKnowIsIgnored() throws {
        var body = try envelope(fullSession).messageBody()
        var session = try XCTUnwrap(body["session"] as? [String: Any])
        session["mood"] = "strong"
        body["session"] = session

        XCTAssertEqual(try SyncEnvelope(messageBody: body).session?.name, "Upper A")
    }

    /// The old shape: a notification that a session ended, with nothing in
    /// it. It still decodes, and `session` is simply absent.
    func testASessionFinishedWithNoPayloadStillDecodes() throws {
        let body = try SyncEnvelope(
            event: .sessionFinished, workoutID: sessionID, revision: 4,
            updatedAt: Date(timeIntervalSince1970: 1_789_894_800), origin: .watchOS,
            heartRate: SessionHeartRate(averageBpm: 128.5, maxBpm: 171)
        ).messageBody()

        let received = try SyncEnvelope(messageBody: body)

        XCTAssertNil(received.session)
        XCTAssertEqual(received.heartRate?.maxBpm, 171)
    }

    // MARK: - Day keys

    func testWireDayIsTheLocalCalendarDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        // 2026-09-21T02:00:00Z is still the 20th in Los Angeles.
        XCTAssertEqual(
            WireDay.key(for: Date(timeIntervalSince1970: 1_789_956_000), calendar: calendar),
            "2026-09-20"
        )
    }
}
