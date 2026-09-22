import XCTest
import SwiftData
import LiftCore
@testable import Lift

/// Per-side prescriptions on the lifter's side (PLAN-FORMAT.md "Sides"): what
/// accepting a plan with `b: 1` and sided set tuples does, what a started
/// session holds, and the targets and suggestions read from it. The rules are
/// LIFT web's `sides.js` and `plan-sides.test.mjs`; these port its cases.
final class PlanSidesTests: XCTestCase {

    private var suite = ""
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suite = "plan-sides-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    private func context() -> ModelContext {
        ModelContext(LiftStore.makeContainer(inMemory: true))
    }

    private func acceptFixture(in context: ModelContext) throws -> Routine {
        let payload = try PlanLinkCodec.decode(fragment: PlanSidesDegradationTests.fixtureFragment(),
                                               expectedLifterID: "a1b2c3d4")
        try PlanImporter.accept(payload, hash: PlanImporter.hash(of: payload), in: context, defaults: defaults)
        return try XCTUnwrap(try context.fetch(FetchDescriptor<Routine>()).first)
    }

    private func kg(_ lb: Double) -> Double { WeightUnit.pounds.toKilograms(lb) }

    // MARK: - Accepting a plan

    func testTheFixtureDecodesWithItsSides() throws {
        let routine = try acceptFixture(in: context())
        let sides = PlanSides.load(from: defaults)
        let e = routine.orderedExercises
        XCTAssertEqual(e.map { sides.isEachSide($0) }, [false, true, true, false, false])
        XCTAssertEqual(e.map { $0.orderedSets.map { sides.side(of: $0) } }, [
            [nil, nil, nil], [nil, nil, nil], [nil, nil, nil, .left], [nil, nil, .right], [.left],
        ])
        // Weights and reps as the coach wrote them, in kilograms.
        XCTAssertEqual(e[3].orderedSets.map(\.targetWeightKg), [kg(60), kg(60), kg(40)])
        XCTAssertEqual(e[3].orderedSets.map(\.targetReps), [8, 8, 10])
        XCTAssertEqual(e[4].orderedSets.first?.targetDistanceMeters, 1600)
    }

    func testAcceptingAnEachSideExerciseTurnsPerSideLoggingOnForThatLiftOnly() throws {
        _ = try acceptFixture(in: context())
        let raw = defaults.string(forKey: PerSideLogging.storageKey) ?? "{}"
        XCTAssertEqual(PerSideLogging.decode(raw), [
            "single-arm dumbbell row|dumbbell": true,
            "bulgarian split squat|dumbbell": true,
        ])
    }

    func testFlagsAreMaskedNeverCompared() throws {
        let flags: [Double] = [2, 4, 3, 5, 6, 0, 1]
        let payload = PlanPayload(v: 1, t: "plan", l: "a1b2c3d4", n: "Doug", r: nil, m: nil,
            w: [PlanWorkout(n: "x", e: [PlanWorkoutExercise(n: "Row", q: nil, c: nil,
                s: flags.map { [30, 8, nil, nil, nil, $0] } + [[30, 8]])])], k: nil)
        let ctx = context()
        try PlanImporter.accept(payload, hash: "masking", in: ctx, defaults: defaults)
        let sets = try XCTUnwrap(try ctx.fetch(FetchDescriptor<Routine>()).first?.orderedExercises.first?.orderedSets)
        let sides = PlanSides.load(from: defaults)
        XCTAssertEqual(sets.map { sides.side(of: $0) }, [.left, .right, .left, .right, nil, nil, nil, nil])
        for set in sets {
            XCTAssertEqual(set.targetWeightKg, kg(30))
            XCTAssertEqual(set.targetReps, 8)
        }
    }

    @MainActor
    func testAPlanWithoutSidesWritesNothingAndTurnsNothingOn() throws {
        let payload = PlanPayload(v: 1, t: "plan", l: "a1b2c3d4", n: "Doug", r: nil, m: nil,
            w: [PlanWorkout(n: "Lower A", e: [PlanWorkoutExercise(n: "Walking Lunge", q: "Dumbbell",
                                                                  c: nil, s: [[40, 8], [40, 8]])])],
            k: nil)
        let ctx = context()
        try PlanImporter.accept(payload, hash: "plain", in: ctx, defaults: defaults)
        XCTAssertNil(defaults.data(forKey: PlanSides.storageKey))
        XCTAssertNil(defaults.string(forKey: PerSideLogging.storageKey))
        let routine = try XCTUnwrap(try ctx.fetch(FetchDescriptor<Routine>()).first)
        let day = routine.startSession(on: .now, in: ctx, defaults: defaults)
        XCTAssertEqual(day.orderedExercises.first?.sets.count, 2, "copied in as it always was")
        XCTAssertTrue(PlanSides.load(from: defaults).logged.isEmpty)
    }

    // MARK: - Starting it

    @MainActor
    func testStartingItLogsSidedSetsAsTheyAreDoneAndCopiesTwoSidedOnesAsBefore() throws {
        let ctx = context()
        let routine = try acceptFixture(in: ctx)
        let day = routine.startSession(on: .now, in: ctx, defaults: defaults)
        let logged = day.orderedExercises
        XCTAssertEqual(logged.map(\.name), ["Back Squat", "Single-Arm Dumbbell Row", "Bulgarian Split Squat",
                                            "Dumbbell Bench Press", "Suitcase Carry"])
        XCTAssertEqual(logged.map { $0.sets.count }, [3, 0, 0, 2, 0])
        XCTAssertEqual(logged[3].orderedSets.map(\.weightKg), [kg(60), kg(60)], "the right one waits")
        XCTAssertTrue(logged[3].orderedSets.allSatisfy { $0.side == nil })

        // Kept with the logged exercise, so a relaunch -- a fresh read of the
        // store it lives in -- still has the targets.
        let reread = PlanSides.load(from: defaults)
        XCTAssertNil(reread.logged[logged[0].id], "nothing about sides: nothing kept")
        XCTAssertEqual(reread.logged[logged[1].id]?.eachSide, true)
        XCTAssertEqual(reread.logged[logged[3].id]?.sets.map(\.side), [nil, nil, .right])
        XCTAssertEqual(reread.logged[logged[4].id]?.sets.first?.durationSec, 600)
    }

    @MainActor
    func testTheHeaderCountsAgainstTheTargetAndShowsOverAsOver() throws {
        let ctx = context()
        let day = try acceptFixture(in: ctx).startSession(on: .now, in: ctx, defaults: defaults)
        let sides = PlanSides.load(from: defaults)
        func label(_ entry: ExerciseEntry) -> String {
            sides.logged[entry.id]?.targetsLabel(logged: entry.orderedSets.map(\.side)) ?? ""
        }
        let e = day.orderedExercises
        XCTAssertEqual(label(e[1]), "L 0/3 · R 0/3")
        XCTAssertEqual(label(e[2]), "L 0/4 · R 0/3", "the seven-set case")
        XCTAssertEqual(label(e[3]), "R 0/1 · 2/2 both")
        XCTAssertEqual(label(e[4]), "L 0/1")
        XCTAssertEqual(label(e[0]), "", "nothing about sides: the plain count stands")

        let row = try XCTUnwrap(sides.logged[e[1].id])
        let seven: [SetSide?] = [.left, .right, .left, .right, .left, .right, .left]
        XCTAssertEqual(row.targetsLabel(logged: seven), "L 4/3 · R 3/3", "over is shown, not capped")
    }

    func testTheSevenSetCaseExpectsFourLeftAndThreeRight() {
        let plain = CoachPrescribedSet(weightKg: 18, reps: 8)
        var extra = plain
        extra.side = .left
        let seven = Prescription(eachSide: true, sets: [plain, plain, plain, extra])
        XCTAssertEqual(seven.targets, Prescription.Targets(left: 4, right: 3, both: 0))
    }

    func testTheSuggestionStartsOnTheSideTheNextUnfilledPrescribedSetNames() {
        let seven = Prescription(eachSide: true, sets: [CoachPrescribedSet(), CoachPrescribedSet(), CoachPrescribedSet(),
                                                        CoachPrescribedSet(side: .left)])
        XCTAssertEqual(seven.nextSide(after: []), .left)
        XCTAssertEqual(seven.nextSide(after: [.left]), .right)
        XCTAssertEqual(seven.nextSide(after: [.left, .left, .left]), .right, "three lefts first leave the rights")
        XCTAssertEqual(seven.nextSide(after: [.left, .right, .left, .right, .left, .right]), .left, "the extra left")
        XCTAssertNil(seven.nextSide(after: [.left, .right, .left, .right, .left, .right, .left]),
                     "filled: back to whichever is behind")
        // A named right set on a two-sided lift: logged both-sides sets fill nothing.
        let bench = Prescription(eachSide: false, sets: [CoachPrescribedSet(), CoachPrescribedSet(), CoachPrescribedSet(side: .right)])
        XCTAssertEqual(bench.nextSide(after: [nil, nil]), .right)
        XCTAssertNil(bench.nextSide(after: [nil, nil, .right]))
    }

    func testANewSetOnASidePrefillsFromThePrescribedSetItAnswers() {
        let a = CoachPrescribedSet(weightKg: 18, reps: 8)
        let b = CoachPrescribedSet(weightKg: 20, reps: 6)
        let extra = CoachPrescribedSet(weightKg: 14, reps: 12, side: .left)
        let seven = Prescription(eachSide: true, sets: [a, a, b, extra])
        XCTAssertEqual(seven.setFor(side: .left, after: []), a)
        XCTAssertEqual(seven.setFor(side: .left, after: [.left, .right, .left, .right]), b)
        XCTAssertEqual(seven.setFor(side: .left, after: [.left, .right, .left, .right, .left, .right]), extra)
        XCTAssertNil(seven.setFor(side: .right, after: [.left, .right, .left, .right, .left, .right]),
                     "right is used up")
        XCTAssertNil(seven.setFor(side: nil, after: []))
    }

    func testAPrescriptionWithoutSidesChangesNothing() {
        let plain = Prescription(eachSide: false, sets: [CoachPrescribedSet(weightKg: 100, reps: 5)])
        XCTAssertFalse(plain.prescribesSides)
        XCTAssertEqual(plain.targetsLabel(logged: []), "")
        XCTAssertNil(plain.nextSide(after: []))
    }

    func testTheStoreRoundTripsThroughUserDefaults() {
        var sides = PlanSides()
        let exercise = UUID(), set = UUID(), entry = UUID()
        sides.eachSide = [exercise]
        sides.sides = [set: .right]
        sides.logged = [entry: Prescription(eachSide: true, sets: [CoachPrescribedSet(weightKg: 18, reps: 8, side: .left)])]
        sides.save(to: defaults)
        XCTAssertEqual(PlanSides.load(from: defaults), sides)
    }
}
