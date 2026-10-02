import XCTest
@testable import LiftKit
import LiftSync

/// Where the lifter is inside a plan, and what happens when they log a set.
final class GuidedSessionTests: XCTestCase {

    private func plan(
        _ exercises: [(name: String, sets: [PrescribedSet])],
        source: WorkoutPlan.Source = .routine
    ) -> WorkoutPlan {
        WorkoutPlan(
            name: "Upper A",
            source: source,
            scheduledFor: "2026-09-20",
            exercises: exercises.map { PlanExercise(name: $0.name, sets: $0.sets) }
        )
    }

    private var threeAndTwo: WorkoutPlan {
        plan([
            ("Bench Press", [
                PrescribedSet(weightKg: 80, reps: 5, restSeconds: 120),
                PrescribedSet(weightKg: 80, reps: 5, restSeconds: 120),
                PrescribedSet(weightKg: 80, reps: 5, restSeconds: 180)
            ]),
            ("Chin Up", [PrescribedSet(reps: 8), PrescribedSet(reps: 8)])
        ])
    }

    // MARK: - Position

    func testOpensOnTheFirstSetOfTheFirstExercise() {
        let session = GuidedSession(plan: threeAndTwo)
        XCTAssertEqual(session.currentExercise?.name, "Bench Press")
        XCTAssertEqual(session.positionText, "1/3")
        XCTAssertEqual(session.currentPrescription?.reps, 5)
        XCTAssertFalse(session.isComplete)
    }

    func testPositionAdvancesWithEachLoggedSet() {
        var session = GuidedSession(plan: threeAndTwo)
        session.recordSet()
        XCTAssertEqual(session.positionText, "2/3")
        session.recordSet()
        XCTAssertEqual(session.positionText, "3/3")
    }

    func testTheNextExerciseStartsWhenThisOnesSetsAreDone() {
        var session = GuidedSession(plan: threeAndTwo)
        session.recordSet()
        session.recordSet()
        XCTAssertEqual(session.currentExercise?.name, "Bench Press")
        session.recordSet()
        XCTAssertEqual(session.currentExercise?.name, "Chin Up")
        XCTAssertEqual(session.positionText, "1/2")
        XCTAssertEqual(session.currentPrescription?.reps, 8)
        XCTAssertNil(session.currentPrescription?.weightKg)
    }

    func testTheSessionIsCompleteWhenEveryExerciseIsDone() {
        var session = GuidedSession(plan: threeAndTwo)
        for _ in 0..<5 { session.recordSet() }
        XCTAssertTrue(session.isComplete)
        XCTAssertNil(session.currentExercise)
        XCTAssertNil(session.currentPrescription)
        XCTAssertEqual(session.positionText, "")
        XCTAssertEqual(session.completedSetCount, 5)
    }

    // MARK: - Rest comes from the set just performed

    func testRecordingASetReturnsThePrescriptionItJustCompleted() {
        var session = GuidedSession(plan: threeAndTwo)
        XCTAssertEqual(session.recordSet()?.restSeconds, 120)
        XCTAssertEqual(session.recordSet()?.restSeconds, 120)
        // The last set of the exercise rests longer, and the rest that
        // starts must be the one attached to the set just finished — not the
        // next set's, and not the next exercise's.
        XCTAssertEqual(session.recordSet()?.restSeconds, 180)
        // First set of the next exercise, which prescribes no rest at all.
        XCTAssertNil(session.recordSet()?.restSeconds)
    }

    func testRecordingASetOnAFinishedSessionChangesNothing() {
        var session = GuidedSession(plan: threeAndTwo)
        for _ in 0..<5 { session.recordSet() }
        let before = session
        XCTAssertNil(session.recordSet())
        XCTAssertEqual(session, before)
    }

    // MARK: - Off the prescription

    func testLoggingMoreSetsThanPrescribedIsNotAnError() {
        // A plan is a prescription, not a limit: the extra set counts, the
        // exercise is finished either way, and nothing here refuses it.
        var session = GuidedSession(plan: plan([("Row", [PrescribedSet(reps: 10)]),
                                                ("Curl", [PrescribedSet(reps: 12)])]))
        session.recordSet()
        XCTAssertEqual(session.currentExercise?.name, "Curl")
        session.select(exerciseIndex: 0)
        session.recordSet()
        XCTAssertEqual(session.completedSets(forExercise: 0), 2)
        XCTAssertFalse(session.isComplete)
    }

    func testAnExercisePrescribingNoSetsIsSkipped() {
        let session = GuidedSession(plan: plan([
            ("Warm-up Bike", []),
            ("Squat", [PrescribedSet(weightKg: 100, reps: 5)])
        ]))
        XCTAssertEqual(session.currentExercise?.name, "Squat")
    }

    func testAnEmptyPlanIsCompleteAndShowsNothing() {
        let session = GuidedSession(plan: plan([]))
        XCTAssertTrue(session.isComplete)
        XCTAssertNil(session.currentExercise)
        XCTAssertEqual(session.positionText, "")
    }

    func testSelectingAnExerciseOutOfOrderMovesThereAndComesBack() {
        var session = GuidedSession(plan: threeAndTwo)
        session.select(exerciseIndex: 1)
        XCTAssertEqual(session.currentExercise?.name, "Chin Up")
        session.recordSet()
        session.recordSet()
        // Chin Ups are done, so the wrap picks up the Bench Press sets the
        // lifter still owes rather than declaring the session over.
        XCTAssertEqual(session.currentExercise?.name, "Bench Press")
        XCTAssertEqual(session.positionText, "1/3")
    }

    func testSelectingAnExerciseThatDoesNotExistIsIgnored() {
        var session = GuidedSession(plan: threeAndTwo)
        session.select(exerciseIndex: 9)
        XCTAssertEqual(session.currentExercise?.name, "Bench Press")
    }

    // MARK: - What the Now screen reads

    func testTheNowScreensLinesForAPartialPrescription() {
        let session = GuidedSession(plan: WorkoutPlan(
            name: "Upper A", source: .coachPlan, scheduledFor: "2026-09-20",
            exercises: [PlanExercise(
                name: "Bench Press", equipment: "barbell", note: nil,
                sets: Array(repeating: PrescribedSet(weightKg: 83.9146, reps: 5), count: 5),
                lastPerformed: LastPerformed(weightKg: 83.9146, reps: 5, rpe: 8)
            )]
        ))
        var moved = session
        moved.recordSet()
        moved.recordSet()

        // Exactly the screen the design spec draws: UPPER A / 3/5 / 185 x 5 /
        // last: 185x5 @8.
        XCTAssertEqual(moved.plan.name, "Upper A")
        XCTAssertEqual(moved.positionText, "3/5")
        XCTAssertEqual(moved.currentPrescription?.headline(unit: .pounds), "185 x 5")
        XCTAssertEqual(moved.currentExercise?.lastPerformed?.summary(unit: .pounds), "185x5 @8")
    }
}
