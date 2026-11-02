import XCTest
@testable import LiftKit
import LiftSync

/// Supersets, circuits, drop sets and rest-pause on the wrist (PLAN-FORMAT.md
/// "Set types"). The labels are LIFT for iPhone's `ExerciseGrouping`, and the
/// order and the rest are its `SessionRest`, ported into `GuidedSession`: the
/// cases below are `SessionRestTests`' and `SetTypesTests`' own, read through
/// the watch's session rather than the phone's day.
final class SetTypesSessionTests: XCTestCase {

    private func set(_ reps: Int, _ kind: PlanSetKind? = nil, rest: Int? = 90) -> PrescribedSet {
        PrescribedSet(reps: reps, restSeconds: rest, kind: kind)
    }

    private func plan(_ exercises: [PlanExercise]) -> WorkoutPlan {
        WorkoutPlan(name: "Upper B", source: .coachPlan, scheduledFor: "2026-10-28",
                    exercises: exercises)
    }

    /// Logs every set the session asks for, on the side it offers, and says
    /// which exercise each one went to and what rest it started.
    private func walk(_ session: inout GuidedSession) -> [(String, GuidedSession.Rest?)] {
        var out: [(String, GuidedSession.Rest?)] = []
        while let exercise = session.currentExercise, out.count < 100 {
            session.recordSet(on: session.currentSide)
            out.append((exercise.name, session.restAfterLastSet))
        }
        return out
    }

    // MARK: - Labels

    func testAdjacencyMakesTheGroupNotTheNumber() {
        XCTAssertEqual(PlanGrouping.runs([7, 7, 3, 3, 3]), [1, 1, 2, 2, 2])
        XCTAssertEqual(PlanGrouping.runs([1, nil, 1]), [nil, nil, nil], "three groups of one are no group")
        XCTAssertEqual(PlanGrouping.runs([2, 2, 2, 5]), [1, 1, 1, nil])
        XCTAssertEqual(PlanGrouping.runs([0, 0, -1, -1]), [nil, nil, nil, nil])
    }

    func testLabelsAndLettersPastZ() {
        XCTAssertEqual(PlanGrouping.labels([nil, 1, 1, 2, 2, 2, nil]).map { $0?.text }, [
            nil, "Superset A · A1", "Superset A · A2",
            "Circuit B · B1", "Circuit B · B2", "Circuit B · B3", nil])
        XCTAssertEqual(PlanGrouping.letters(0), "A")
        XCTAssertEqual(PlanGrouping.letters(25), "Z")
        XCTAssertEqual(PlanGrouping.letters(26), "AA")
        XCTAssertEqual(PlanGrouping.letters(27), "AB")
    }

    func testTheNowScreenNamesTheGroupItIsIn() {
        var session = GuidedSession(plan: plan([
            PlanExercise(name: "Squat", sets: [set(5)]),
            PlanExercise(name: "Dumbbell Bench Press", sets: [set(10)], group: 4),
            PlanExercise(name: "Seated Cable Rows", sets: [set(12)], group: 4)
        ]))
        XCTAssertNil(session.currentGroupLabel)
        session.recordSet()
        XCTAssertEqual(session.currentGroupLabel?.text, "Superset A · A1")
        session.recordSet()
        XCTAssertEqual(session.currentGroupLabel?.text, "Superset A · A2")
    }

    // MARK: - The order

    func testASupersetGoesRoundByRoundWithTheRestAfterTheRound() {
        var session = GuidedSession(plan: plan([
            PlanExercise(name: "Dumbbell Bench Press", sets: [set(10), set(10), set(10)], group: 1),
            PlanExercise(name: "Seated Cable Rows", sets: [set(12), set(12), set(12)], group: 1)
        ]))
        let steps = walk(&session)
        XCTAssertEqual(steps.map(\.0), ["Dumbbell Bench Press", "Seated Cable Rows",
                                        "Dumbbell Bench Press", "Seated Cable Rows",
                                        "Dumbbell Bench Press", "Seated Cable Rows"])
        XCTAssertEqual(steps.map(\.1), [.none(cue: "Next: Seated Cable Rows"), .full,
                                        .none(cue: "Next: Seated Cable Rows"), .full,
                                        .none(cue: "Next: Seated Cable Rows"), .full])
        XCTAssertTrue(session.isComplete)
    }

    func testACircuitSkipsAMemberThatHasRunOut() {
        // `SessionRestTests`' circuit: three swings, three push-ups, two
        // planks -- round three is swing then push-up.
        var session = GuidedSession(plan: plan([
            PlanExercise(name: "Kettlebell Swing", sets: [set(15), set(15), set(15)], group: 2),
            PlanExercise(name: "Push-Up", sets: [set(20), set(20), set(20)], group: 2),
            PlanExercise(name: "Plank", sets: [set(1), set(1)], group: 2)
        ]))
        XCTAssertEqual(session.currentGroupLabel?.text, "Circuit A · A1")
        let steps = walk(&session)
        XCTAssertEqual(steps.map(\.0), ["Kettlebell Swing", "Push-Up", "Plank",
                                        "Kettlebell Swing", "Push-Up", "Plank",
                                        "Kettlebell Swing", "Push-Up"])
        XCTAssertEqual(steps[6].1, .none(cue: "Next: Push-Up"))
        XCTAssertEqual(steps[7].1, .full, "the round's last set starts the full rest")
    }

    func testARoundIsNotOverWhileAnEarlierSetOfItIsStillToDo() {
        // Rows opened first, out of order: bench is still owed in round one.
        var session = GuidedSession(plan: plan([
            PlanExercise(name: "Bench", sets: [set(10), set(10)], group: 1),
            PlanExercise(name: "Rows", sets: [set(12), set(12)], group: 1)
        ]))
        session.select(exerciseIndex: 1)
        session.recordSet()
        XCTAssertEqual(session.restAfterLastSet, .none(cue: "Next: Bench"))
        XCTAssertEqual(session.currentExercise?.name, "Bench")
    }

    func testAnEachSideMemberDoesBothSidesInItsRound() {
        // A decision, not a port: the phone logs a sided set when it is
        // done, so its round has no each-side row to hold. On the watch one
        // prescribed row is one place in the round, both sides of it.
        var session = GuidedSession(plan: plan([
            PlanExercise(name: "Split Squat", sets: [set(8), set(8)], eachSide: true, group: 1),
            PlanExercise(name: "Rows", sets: [set(12), set(12)], group: 1)
        ]))
        var lines: [String] = []
        var rests: [GuidedSession.Rest?] = []
        while let exercise = session.currentExercise {
            lines.append("\(exercise.name) \(session.positionText)")
            session.recordSet(on: session.currentSide)
            rests.append(session.restAfterLastSet)
        }
        XCTAssertEqual(lines, ["Split Squat 1/4 · L", "Split Squat 2/4 · R", "Rows 1/2",
                               "Split Squat 3/4 · L", "Split Squat 4/4 · R", "Rows 2/2"])
        XCTAssertEqual(rests, [.none(cue: "Next: Split Squat"), .none(cue: "Next: Rows"), .full,
                               .none(cue: "Next: Split Squat"), .none(cue: "Next: Rows"), .full])
    }

    // MARK: - Drop sets and rest-pause

    func testADropSetNextMeansNoRest() {
        var session = GuidedSession(plan: plan([
            PlanExercise(name: "Triceps Pushdown",
                         sets: [set(12), set(12), set(10, .drop), set(10, .drop)])
        ]))
        XCTAssertEqual(session.positionText, "1/4")
        session.recordSet()
        XCTAssertEqual(session.restAfterLastSet, .full)
        XCTAssertEqual(session.positionText, "2/4")
        session.recordSet()
        XCTAssertEqual(session.restAfterLastSet, .none(cue: "Drop set next"))
        XCTAssertEqual(session.positionText, "3/4 · drop")
        XCTAssertEqual(session.currentKind, .drop)
        session.recordSet()
        XCTAssertEqual(session.restAfterLastSet, .none(cue: "Drop set next"), "a drop after a drop")
        session.recordSet()
        XCTAssertEqual(session.restAfterLastSet, .full)
    }

    func testRestPauseNextIsFifteenSeconds() {
        var session = GuidedSession(plan: plan([
            PlanExercise(name: "Barbell Curl", sets: [set(8, rest: 120), set(4, .restPause)])
        ]))
        session.recordSet()
        XCTAssertEqual(session.restAfterLastSet, .short(seconds: 15))
        XCTAssertEqual(GuidedSession.restPauseSeconds, 15)
        XCTAssertEqual(session.positionText, "2/2 · rest-pause")
    }

    func testAFirstSetIsNeverADropSet() {
        // A first set saying drop is read as straight: nothing before it to
        // drop from, so the exercise before it rests in full and the Now
        // screen does not say "drop".
        var session = GuidedSession(plan: plan([
            PlanExercise(name: "Squat", sets: [set(5)]),
            PlanExercise(name: "Pushdown", sets: [set(12, .drop), set(10, .drop)])
        ]))
        session.recordSet()
        XCTAssertEqual(session.restAfterLastSet, .full)
        XCTAssertEqual(session.positionText, "1/2")
        XCTAssertNil(session.currentKind)
        session.recordSet()
        XCTAssertEqual(session.restAfterLastSet, .none(cue: "Drop set next"))
    }

    func testASideAndAKindReadSideThenKind() {
        // The phone's order: "30 x 12 L drop".
        var session = GuidedSession(plan: plan([
            PlanExercise(name: "Split Squat",
                         sets: [PrescribedSet(weightKg: 13.6078, reps: 8),
                                PrescribedSet(weightKg: 13.6078, reps: 8),
                                PrescribedSet(weightKg: 9.07185, reps: 8, kind: .drop)],
                         eachSide: true)
        ]))
        for _ in 0..<4 { session.recordSet(on: session.currentSide) }
        XCTAssertEqual(session.positionText, "5/6 · L drop")
        XCTAssertEqual(session.currentPrescription?.summary(unit: .pounds, side: session.currentSide,
                                                            kind: session.currentKind),
                       "20 x 8 · L drop")
    }

    func testAnExtraSetPastThePlanIsStraightAndRestsInFull() {
        var session = GuidedSession(plan: plan([
            PlanExercise(name: "Pushdown", sets: [set(12), set(10, .drop)]),
            PlanExercise(name: "Curl", sets: [set(8)])
        ]))
        session.recordSet()
        session.recordSet()
        session.select(exerciseIndex: 0)
        XCTAssertNil(session.currentKind, "past the prescription, no instruction to strip the bar")
        session.recordSet()
        XCTAssertEqual(session.restAfterLastSet, .full)
    }

    // MARK: - Nothing changes without them

    func testAPlanWithNoSetTypesRestsInFullAndGoesInOrder() {
        var session = GuidedSession(plan: plan([
            PlanExercise(name: "Bench", sets: [set(5), set(5)]),
            PlanExercise(name: "Row", sets: [set(8), set(8)])
        ]))
        XCTAssertNil(session.restAfterLastSet)
        let steps = walk(&session)
        XCTAssertEqual(steps.map(\.0), ["Bench", "Bench", "Row", "Row"])
        XCTAssertEqual(steps.map(\.1), [.full, .full, .full, .full])
        XCTAssertNil(GuidedSession(plan: plan([PlanExercise(name: "Bench", sets: [set(5)])]))
            .currentGroupLabel)
    }

    // MARK: - The design's example, whole

    func testTheDesignsExampleTrainsAsTheDesignSaysItShould() {
        // `2026-10-28-set-types-design.md` "Example": a superset of bench
        // and rows, three rounds; a pushdown, two straight then two drops;
        // a curl, eight then rest-pause four.
        var session = GuidedSession(plan: plan([
            PlanExercise(name: "Dumbbell Bench Press", sets: [set(10), set(10), set(10)], group: 1),
            PlanExercise(name: "Seated Cable Rows", sets: [set(12), set(12), set(12)], group: 1),
            PlanExercise(name: "Triceps Pushdown",
                         sets: [set(12), set(12), set(10, .drop), set(10, .drop)]),
            PlanExercise(name: "Barbell Curl", sets: [set(8), set(4, .restPause)])
        ]))
        XCTAssertEqual(session.plan.groupLabels.map { $0?.text },
                       ["Superset A · A1", "Superset A · A2", nil, nil])
        let steps = walk(&session)
        XCTAssertEqual(steps.count, 12)
        XCTAssertEqual(steps.map(\.1), [
            .none(cue: "Next: Seated Cable Rows"), .full,
            .none(cue: "Next: Seated Cable Rows"), .full,
            .none(cue: "Next: Seated Cable Rows"), .full,
            .full, .none(cue: "Drop set next"), .none(cue: "Drop set next"), .full,
            .short(seconds: 15), .full
        ])
        XCTAssertTrue(session.isComplete)
    }
}
