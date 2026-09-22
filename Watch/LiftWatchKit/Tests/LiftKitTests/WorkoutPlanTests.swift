import XCTest
@testable import LiftKit
import LiftSync

/// The watch's half of the `PLAN_PUSHED` contract in
/// `Watch/contracts/workout-sync.schema.json`. `LiftSyncTests`'
/// `WatchPlanWireTests` pins the key spellings the phone encodes; these tests
/// decode what that encoder actually produces, and pin what this side renders
/// from it — in particular that a blank prescription never becomes a zero on
/// a wrist.
final class WorkoutPlanTests: XCTestCase {

    /// The exact shape `lift-ios` sends: absent keys for everything blank,
    /// `weightKg` in kilograms, `source` in SCREAMING_SNAKE.
    private let phoneJSON = Data("""
    {"event":"PLAN_PUSHED","workoutId":"6A2A8B6E-3D2F-4E77-9B4E-2C6A5E8C1D01",
     "revision":3,"updatedAt":"2026-09-20T09:00:00Z","origin":"ios",
     "plan":{"name":"Upper A","source":"COACH_PLAN","scheduledFor":"2026-09-20",
       "exercises":[
         {"name":"Bench Press","equipment":"barbell","note":"Two second pause",
          "sets":[{"weightKg":83.9146,"reps":5,"rpe":8,"restSeconds":120},
                  {"reps":5,"restSeconds":120}],
          "lastPerformed":{"weightKg":83.9146,"reps":5,"rpe":8,"performedOn":"2026-09-13"}},
         {"name":"Chin Up","sets":[{"reps":8},{}]}]}}
    """.utf8)

    // MARK: - Decoding what the phone sends

    func testDecodesThePhonesPlanPushed() throws {
        let envelope = try SyncEnvelope.decoder.decode(SyncEnvelope.self, from: phoneJSON)

        XCTAssertEqual(envelope.event, .planPushed)
        XCTAssertEqual(envelope.origin, .ios)
        XCTAssertEqual(envelope.revision, 3)

        let plan = try XCTUnwrap(envelope.plan)
        XCTAssertEqual(plan.name, "Upper A")
        XCTAssertEqual(plan.source, .coachPlan)
        XCTAssertEqual(plan.scheduledFor, "2026-09-20")
        XCTAssertEqual(plan.exercises.count, 2)
        XCTAssertEqual(plan.totalSetCount, 4)

        let bench = plan.exercises[0]
        XCTAssertEqual(bench.displayName, "Bench Press (Barbell)")
        XCTAssertEqual(bench.note, "Two second pause")
        XCTAssertEqual(bench.sets[0].weightKg ?? 0, 83.9146, accuracy: 0.0001)
        XCTAssertEqual(bench.sets[0].restSeconds, 120)
        XCTAssertEqual(bench.lastPerformed?.performedOn, "2026-09-13")

        // "[null, 5]" — five reps, you pick the weight.
        XCTAssertNil(bench.sets[1].weightKg)
        XCTAssertEqual(bench.sets[1].reps, 5)

        let chins = plan.exercises[1]
        XCTAssertNil(chins.equipment)
        XCTAssertEqual(chins.displayName, "Chin Up")
        XCTAssertNil(chins.lastPerformed)
        XCTAssertTrue(chins.sets[1].isEmpty)
    }

    func testReEncodesUnderTheContractsOwnKeyNames() throws {
        let envelope = try SyncEnvelope.decoder.decode(SyncEnvelope.self, from: phoneJSON)
        let data = try SyncEnvelope.encoder.encode(envelope)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["event"] as? String, "PLAN_PUSHED")
        let plan = try XCTUnwrap(object["plan"] as? [String: Any])
        XCTAssertEqual(Set(plan.keys), ["name", "source", "scheduledFor", "exercises"])
        XCTAssertEqual(plan["source"] as? String, "COACH_PLAN")

        let exercises = try XCTUnwrap(plan["exercises"] as? [[String: Any]])
        XCTAssertEqual(Set(exercises[0].keys), ["name", "equipment", "note", "sets", "lastPerformed"])
        // A blank stays an absent key on the way back out, too: nothing here
        // may turn "you pick the weight" into `"weightKg": null`, let alone 0.
        let benchSets = try XCTUnwrap(exercises[0]["sets"] as? [[String: Any]])
        XCTAssertEqual(Set(benchSets[1].keys), ["reps", "restSeconds"])
        XCTAssertEqual(Set(exercises[1].keys), ["name", "sets"])
    }

    func testPlanRoundTrips() throws {
        let envelope = try SyncEnvelope.decoder.decode(SyncEnvelope.self, from: phoneJSON)
        let data = try SyncEnvelope.encoder.encode(envelope)
        XCTAssertEqual(try SyncEnvelope.decoder.decode(SyncEnvelope.self, from: data), envelope)
    }

    func testAnUnknownEventIsRefusedSoAnOlderBuildIgnoresIt() {
        let data = Data("""
        {"event":"SOMETHING_NEWER","workoutId":"6A2A8B6E-3D2F-4E77-9B4E-2C6A5E8C1D01",
         "revision":1,"updatedAt":"1970-01-01T00:00:00Z","origin":"ios"}
        """.utf8)
        // Every transport in this app decodes with `try?`, so a throw here is
        // exactly the schema's "ignore what you do not know".
        XCTAssertThrowsError(try SyncEnvelope.decoder.decode(SyncEnvelope.self, from: data))
    }

    func testPlanRequestIsABareEnvelope() throws {
        let envelope = SyncEnvelope(event: .planRequest, workoutID: UUID(), revision: 1,
                                    updatedAt: Date(timeIntervalSince1970: 0), origin: .watchOS)
        let data = try SyncEnvelope.encoder.encode(envelope)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["event"] as? String, "PLAN_REQUEST")
        XCTAssertEqual(Set(object.keys), ["event", "workoutId", "revision", "updatedAt", "origin"])
    }

    // MARK: - Heart rate home

    func testSessionFinishedCarriesHeartRate() throws {
        let envelope = SyncEnvelope(
            event: .sessionFinished, workoutID: UUID(), revision: 6,
            updatedAt: Date(timeIntervalSince1970: 0), origin: .watchOS,
            heartRate: SessionHeartRate(averageBpm: 128.5, maxBpm: 171)
        )
        let data = try SyncEnvelope.encoder.encode(envelope)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let heartRate = try XCTUnwrap(object["heartRate"] as? [String: Any])
        XCTAssertEqual(Set(heartRate.keys), ["averageBpm", "maxBpm"])
        XCTAssertEqual(heartRate["averageBpm"] as? Double, 128.5)
        XCTAssertEqual(try SyncEnvelope.decoder.decode(SyncEnvelope.self, from: data), envelope)
    }

    func testAFinishedSessionWithNoHeartRateOmitsTheKey() throws {
        let envelope = SyncEnvelope(event: .sessionFinished, workoutID: UUID(), revision: 1,
                                    updatedAt: Date(timeIntervalSince1970: 0), origin: .watchOS)
        let data = try SyncEnvelope.encoder.encode(envelope)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertFalse(object.keys.contains("heartRate"))
        XCTAssertFalse(object.keys.contains("plan"))
    }

    // MARK: - Blank never renders as zero

    func testHeadlineRendersWhatIsPrescribedAndNothingMore() {
        let full = PrescribedSet(weightKg: 83.9146, reps: 5, rpe: 8)
        XCTAssertEqual(full.headline(unit: .pounds), "185 x 5")
        XCTAssertEqual(full.summary(unit: .pounds), "185 x 5 @8")
        XCTAssertEqual(full.headline(unit: .kilograms), "83.9 x 5")

        // The prescription the whole rule exists for.
        XCTAssertEqual(PrescribedSet(reps: 5).headline(unit: .pounds), "5 reps")
        // A weight with no rep target — an AMRAP, or a carry.
        XCTAssertEqual(PrescribedSet(weightKg: 40).headline(unit: .kilograms), "40 kg")
        // Nothing at all is a dash, never "0 x 0".
        XCTAssertEqual(PrescribedSet().headline(unit: .pounds), "—")
        XCTAssertEqual(PrescribedSet().summary(unit: .pounds), "—")
    }

    func testHalfStepRPEAndHalfKiloWeightsKeepTheirDecimal() {
        let set = PrescribedSet(weightKg: 82.5, reps: 3, rpe: 7.5)
        XCTAssertEqual(set.summary(unit: .kilograms), "82.5 x 3 @7.5")
    }

    func testLastPerformedSummaryIsNilRatherThanADashWhenItHoldsNothing() {
        XCTAssertNil(LastPerformed().summary(unit: .pounds))
        XCTAssertEqual(
            LastPerformed(weightKg: 83.9146, reps: 5, rpe: 8).summary(unit: .pounds),
            "185x5 @8"
        )
        XCTAssertEqual(LastPerformed(reps: 12).summary(unit: .pounds), "12 reps")
    }

    // MARK: - Which day a plan is for

    private var chicago: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        return calendar
    }

    private func plan(for day: String?) -> WorkoutPlan {
        WorkoutPlan(name: "Push", source: .routine, scheduledFor: day, exercises: [])
    }

    func testAPlanIsForItsOwnLocalDayOnly() {
        // 2026-09-22 08:00 in Chicago.
        let tuesdayMorning = Date(timeIntervalSince1970: 1_790_082_000)
        XCTAssertTrue(plan(for: "2026-09-22").isScheduled(for: tuesdayMorning, calendar: chicago))
        XCTAssertFalse(plan(for: "2026-09-21").isScheduled(for: tuesdayMorning, calendar: chicago))
        XCTAssertFalse(plan(for: "2026-09-23").isScheduled(for: tuesdayMorning, calendar: chicago))
    }

    /// The day is the wearer's local one, not UTC's: 23:30 on Monday in
    /// Chicago is already Tuesday in UTC.
    func testTheDayIsLocalNotUTC() {
        let mondayLateEvening = Date(timeIntervalSince1970: 1_790_051_400) // 2026-09-21 23:30 CDT
        XCTAssertTrue(plan(for: "2026-09-21").isScheduled(for: mondayLateEvening, calendar: chicago))
        XCTAssertFalse(plan(for: "2026-09-22").isScheduled(for: mondayLateEvening, calendar: chicago))
    }

    func testAPlanWithNoDayIsAlwaysCurrent() {
        XCTAssertTrue(plan(for: nil).isScheduled(for: .now))
    }
}
