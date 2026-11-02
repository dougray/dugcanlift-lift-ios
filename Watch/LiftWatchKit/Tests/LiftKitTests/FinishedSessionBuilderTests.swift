import XCTest
import LiftSync
@testable import LiftKit

/// What the watch hands the phone when a session is finished. The draft is
/// the watch's only record of a workout, so anything this drops is lost:
/// these check that every set, and everything on it, is still there.
final class FinishedSessionBuilderTests: XCTestCase {

    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        return calendar
    }()

    private let start = Date(timeIntervalSince1970: 1_789_891_200)  // 2026-09-20 09:00 BST

    private func draft(name: String = "Upper A") -> WorkoutDraft {
        WorkoutDraft(name: name, now: start)
    }

    func testEverySetTravelsWithItsWeightRepsRPEAndWarmupFlag() {
        var draft = draft()
        let bench = draft.addExercise(refID: "plan:0", name: "Bench Press",
                                      equipment: "barbell", now: start)
        draft.appendSet(to: bench, weightKg: 60, reps: 8, isWarmup: true, now: start)
        draft.appendSet(to: bench, weightKg: 83.9146, reps: 5, rpe: 8, now: start)
        draft.finish(at: start.addingTimeInterval(3600))

        let session = draft.finishedSession(calendar: calendar)

        XCTAssertEqual(session.name, "Upper A")
        XCTAssertEqual(session.performedOn, "2026-09-20")
        XCTAssertEqual(session.startedAt, start)
        XCTAssertEqual(session.finishedAt, start.addingTimeInterval(3600))
        XCTAssertEqual(session.exercises.count, 1)
        XCTAssertEqual(session.exercises[0].name, "Bench Press")
        XCTAssertEqual(session.exercises[0].equipment, "barbell")
        XCTAssertEqual(session.exercises[0].sets.map(\.weightKg), [60, 83.9146])
        XCTAssertEqual(session.exercises[0].sets.map(\.reps), [8, 5])
        XCTAssertEqual(session.exercises[0].sets.map(\.rpe), [nil, 8])
        XCTAssertEqual(session.exercises[0].sets.map(\.isWarmup), [true, false])
    }

    /// The reason this branch is based on the per-side work: a limb logged
    /// on the wrist has to be the same limb on the phone.
    func testSidesTravelSetForSet() {
        var draft = draft(name: "Lower")
        let squat = draft.addExercise(refID: "plan:0", name: "Bulgarian Split Squat",
                                      equipment: "dumbbell", now: start)
        draft.appendSet(to: squat, weightKg: 30, reps: 8, rpe: 8, side: .left, now: start)
        draft.appendSet(to: squat, weightKg: 30, reps: 7, rpe: 9, side: .right, now: start)
        draft.finish(at: start)

        let sets = draft.finishedSession(calendar: calendar).exercises[0].sets

        XCTAssertEqual(sets.map(\.side), [.left, .right])
        XCTAssertEqual(sets.map(\.reps), [8, 7])
    }

    /// A session nobody logged a side on says nothing about sides at all.
    func testASessionWithNoSidesCarriesNone() {
        var draft = draft()
        let deadlift = draft.addExercise(refID: "plan:0", name: "Deadlift", now: start)
        draft.appendSet(to: deadlift, weightKg: 140, reps: 3, now: start)
        draft.finish(at: start)

        let session = draft.finishedSession(calendar: calendar)

        XCTAssertEqual(session.exercises[0].sets.map(\.side), [nil])
        XCTAssertNil(session.exercises[0].equipment)
    }

    /// Order is the order they were trained in, whatever order the arrays
    /// happen to be in.
    func testExercisesAndSetsKeepTheirOrder() {
        var draft = draft()
        let first = draft.addExercise(refID: "plan:0", name: "Squat", now: start)
        let second = draft.addExercise(refID: "plan:1", name: "Row", now: start)
        draft.appendSet(to: second, weightKg: 70, reps: 10, now: start)
        draft.appendSet(to: first, weightKg: 100, reps: 5, now: start)
        draft.appendSet(to: first, weightKg: 105, reps: 5, now: start)
        draft.finish(at: start)

        let session = draft.finishedSession(calendar: calendar)

        XCTAssertEqual(session.exercises.map(\.name), ["Squat", "Row"])
        XCTAssertEqual(session.exercises[0].sets.map(\.weightKg), [100, 105])
    }

    /// The day the session **started**. A set logged at ten past midnight
    /// belongs to the evening it began, which is how the phone's day of
    /// record works — taking it from `finishedAt` would file it under
    /// tomorrow.
    func testTheDayIsTheDayTheSessionStarted() {
        // 2026-09-20 23:30 BST
        let lateStart = Date(timeIntervalSince1970: 1_789_943_400)
        var draft = WorkoutDraft(name: "Late", now: lateStart)
        let squat = draft.addExercise(refID: "plan:0", name: "Squat", now: lateStart)
        draft.appendSet(to: squat, weightKg: 100, reps: 5, now: lateStart)
        draft.finish(at: lateStart.addingTimeInterval(3600))   // past midnight

        let session = draft.finishedSession(calendar: calendar)

        XCTAssertEqual(session.performedOn, "2026-09-20")
    }

    /// A draft with no name would leave the phone's day unnamed; "Workout"
    /// is at least true.
    func testAnUnnamedSessionGetsAName() {
        var draft = WorkoutDraft(name: "   ", now: start)
        let squat = draft.addExercise(refID: "plan:0", name: "Squat", now: start)
        draft.appendSet(to: squat, weightKg: 100, reps: 5, now: start)
        draft.finish(at: start)

        XCTAssertEqual(draft.finishedSession(calendar: calendar).name, "Workout")
    }

    /// Finishing is what sends it, but a payload built from a draft that has
    /// not been finished still says when it was last touched rather than
    /// nothing at all.
    func testAnUnfinishedDraftFallsBackToItsLastEdit() {
        var draft = draft()
        let squat = draft.addExercise(refID: "plan:0", name: "Squat",
                                      now: start.addingTimeInterval(600))
        draft.appendSet(to: squat, weightKg: 100, reps: 5, now: start.addingTimeInterval(900))

        XCTAssertEqual(draft.finishedSession(calendar: calendar).finishedAt,
                       start.addingTimeInterval(900))
    }
}
