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

    // MARK: - Sides

    /// "3 x 8 each side": three prescribed rows, six sets, alternating.
    private var eachSideSplitSquat: WorkoutPlan {
        WorkoutPlan(
            name: "Lower A", source: .coachPlan, scheduledFor: "2026-09-20",
            exercises: [PlanExercise(
                name: "Bulgarian Split Squat",
                equipment: "dumbbell",
                sets: Array(repeating: PrescribedSet(weightKg: 13.6078, reps: 8,
                                                     restSeconds: 90), count: 3),
                eachSide: true
            )]
        )
    }

    func testAnEachSideExerciseIsTwiceTheSetsAndOpensOnTheLeft() {
        let session = GuidedSession(plan: eachSideSplitSquat)
        XCTAssertEqual(session.currentSetCount, 6)
        XCTAssertEqual(session.plan.totalSetCount, 6)
        XCTAssertEqual(session.currentSide, .left)
        // The line the spec draws.
        XCTAssertEqual(session.positionText, "1/6 · L")
    }

    func testAnEachSideExerciseAlternatesAndTakesSixSetsToFinish() {
        var session = GuidedSession(plan: eachSideSplitSquat)
        var sides: [PlanSide?] = []
        for _ in 0..<6 {
            let side = session.currentSide
            sides.append(side)
            session.recordSet(on: side)
        }
        XCTAssertEqual(sides, [.left, .right, .left, .right, .left, .right])
        XCTAssertTrue(session.isComplete)
        XCTAssertEqual(session.completedSetCount, 6)
    }

    func testThePositionCountsEverySetAndNamesTheSideItIsFor() {
        var session = GuidedSession(plan: eachSideSplitSquat)
        session.recordSet(on: .left)
        XCTAssertEqual(session.positionText, "2/6 · R")
        session.recordSet(on: .right)
        XCTAssertEqual(session.positionText, "3/6 · L")
    }

    func testTheSideFollowsWhatWasLoggedNotWhatWasAsked() {
        // The lifter did both left sets first. The plan still owes two
        // rights, so that is what comes next — whichever side is behind, the
        // phone's own rule.
        var session = GuidedSession(plan: eachSideSplitSquat)
        session.recordSet(on: .left)
        session.recordSet(on: .left)
        XCTAssertEqual(session.currentSide, .right)
        session.recordSet(on: .right)
        XCTAssertEqual(session.currentSide, .right)
    }

    func testANamedSideSetIsPerformedOnceOnThatSide() {
        // A bench session with one right-side set in it: nothing else about
        // the exercise is per side, so it is three sets, and only the named
        // one has a side.
        var session = GuidedSession(plan: plan([("Bench Press", [
            PrescribedSet(weightKg: 60, reps: 8),
            PrescribedSet(weightKg: 60, reps: 8),
            PrescribedSet(weightKg: 13.6078, reps: 8, side: .right)
        ])]))
        XCTAssertEqual(session.currentSetCount, 3)
        XCTAssertEqual(session.currentSide, .right)
        XCTAssertEqual(session.positionText, "1/3 · R")
        XCTAssertEqual(session.currentPrescription?.headline(unit: .pounds,
                                                             side: session.currentSide),
                       "30 x 8 · R")
        session.recordSet(on: .right)
        // The sided set is filled, so nothing more is asked of a side.
        XCTAssertNil(session.currentSide)
        XCTAssertEqual(session.positionText, "2/3")
    }

    func testEachSidePlusAnExtraLeftSetIsSevenSetsFourLeftAndThreeRight() {
        // The spec's combination case, exactly: "3 x 8 each side, plus one
        // more on the left".
        var session = GuidedSession(plan: WorkoutPlan(
            name: "Lower A", source: .coachPlan, scheduledFor: "2026-09-20",
            exercises: [PlanExercise(
                name: "Split Squat",
                sets: [PrescribedSet(weightKg: 20, reps: 8),
                       PrescribedSet(weightKg: 20, reps: 8),
                       PrescribedSet(weightKg: 20, reps: 8),
                       PrescribedSet(weightKg: 15, reps: 8, side: .left)],
                eachSide: true
            )]
        ))
        XCTAssertEqual(session.currentSetCount, 7)

        var sides: [PlanSide?] = []
        while !session.isComplete {
            let side = session.currentSide
            sides.append(side)
            session.recordSet(on: side)
        }
        XCTAssertEqual(sides.filter { $0 == .left }.count, 4)
        XCTAssertEqual(sides.filter { $0 == .right }.count, 3)
        XCTAssertEqual(sides.count, 7)
    }

    func testEachSidesPrescriptionIsReadSideBySide() {
        // Left and right take their numbers from the same prescribed row, so
        // logging all three lefts first still leaves the first right the
        // first row's weight.
        var session = GuidedSession(plan: WorkoutPlan(
            name: "Lower A", source: .routine, scheduledFor: "2026-09-20",
            exercises: [PlanExercise(
                name: "Split Squat",
                sets: [PrescribedSet(weightKg: 20, reps: 8),
                       PrescribedSet(weightKg: 22.5, reps: 6),
                       PrescribedSet(weightKg: 25, reps: 4)],
                eachSide: true
            )]
        ))
        session.recordSet(on: .left)
        session.recordSet(on: .left)
        session.recordSet(on: .left)
        XCTAssertEqual(session.currentSide, .right)
        XCTAssertEqual(session.currentPrescription?.weightKg, 20)
        XCTAssertEqual(session.currentPrescription?.reps, 8)
    }

    func testAnExtraSetPastAnEachSidePrescriptionLandsOnTheSideThatIsBehind() {
        var session = GuidedSession(plan: WorkoutPlan(
            name: "Lower A", source: .routine, scheduledFor: "2026-09-20",
            exercises: [
                PlanExercise(name: "Split Squat",
                             sets: [PrescribedSet(weightKg: 20, reps: 8),
                                    PrescribedSet(weightKg: 20, reps: 8)],
                             eachSide: true),
                PlanExercise(name: "Calf Raise", sets: [PrescribedSet(reps: 15)])
            ]
        ))
        for _ in 0..<4 { session.recordSet(on: session.currentSide) }
        XCTAssertEqual(session.currentExercise?.name, "Calf Raise")

        // Back for a fifth set the coach did not ask for. Every prescribed
        // set is filled and the sides are level, so left breaks the tie,
        // exactly as `ExerciseEntry.nextSide` does on the phone.
        session.select(exerciseIndex: 0)
        XCTAssertEqual(session.currentSide, .left)
        XCTAssertEqual(session.currentPrescription?.weightKg, 20)
        session.recordSet(on: .left)

        // That set finished this exercise's sets again, so the session moved
        // on to the one still owed. Coming back, the left is now one ahead.
        XCTAssertEqual(session.currentExercise?.name, "Calf Raise")
        session.select(exerciseIndex: 0)
        XCTAssertEqual(session.currentSide, .right)
    }

    func testRestStillComesFromTheSetJustPerformedOnAnEachSideExercise() {
        var session = GuidedSession(plan: eachSideSplitSquat)
        XCTAssertEqual(session.recordSet(on: .left)?.restSeconds, 90)
        XCTAssertEqual(session.recordSet(on: .right)?.restSeconds, 90)
    }

    func testAPlanWithNoSidesBehavesExactlyAsBefore() {
        // The whole rule, in one test: nothing about a plan that says nothing
        // about sides changes.
        var session = GuidedSession(plan: threeAndTwo)
        XCTAssertNil(session.currentSide)
        XCTAssertEqual(session.positionText, "1/3")
        XCTAssertEqual(session.currentSetCount, 3)
        XCTAssertEqual(session.plan.totalSetCount, 5)
        session.recordSet()
        XCTAssertEqual(session.positionText, "2/3")
        XCTAssertNil(session.currentSide)
        XCTAssertEqual(session.loggedSides[0], [nil])
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
