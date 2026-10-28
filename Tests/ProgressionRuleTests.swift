import XCTest
import SwiftData
import LiftCore
@testable import Lift

@MainActor
final class ProgressionRuleTests: XCTestCase {
    private let monday = Date(timeIntervalSince1970: 1_800_000_000)
    private let earlier = Date(timeIntervalSince1970: 1_799_500_000)

    private func session(_ weight: Double, _ reps: [Int], on date: Date? = nil) -> ProgressionRule.Session {
        ProgressionRule.Session(date: date ?? monday,
                                sets: reps.map { ProgressionRule.LoggedSet(weight: weight, reps: $0) })
    }

    func testEverySetReachedItsRepsGoesUpAStep() {
        let next = ProgressionRule.next(target: 8, setCount: 3,
                                        sessions: [session(185, [8, 8, 9])], step: 5)
        XCTAssertEqual(next, .up(to: 190, from: 185, reps: 8, date: monday))
    }

    func testOneShortSetMeansTheSameWeightAgain() {
        let next = ProgressionRule.next(target: 8, setCount: 3,
                                        sessions: [session(185, [8, 8, 6])], step: 5)
        XCTAssertEqual(next, .same(185, reps: [8, 8, 6], target: 8, date: monday))
    }

    /// Two sets of eight is not three sets of eight.
    func testFewerSetsThanTheRoutineAsksForIsNotDone() {
        let next = ProgressionRule.next(target: 8, setCount: 3,
                                        sessions: [session(185, [8, 8])], step: 5)
        XCTAssertEqual(next?.weight, 185)
    }

    /// The top weight decides: a lighter back-off set short of the reps does
    /// not hold back a session whose heavy sets all got there.
    func testOnlyTheTopWeightsSetsCount() {
        var last = session(185, [8, 8, 8])
        last.sets.append(.init(weight: 135, reps: 5))
        let next = ProgressionRule.next(target: 8, setCount: 3, sessions: [last], step: 5)
        XCTAssertEqual(next?.weight, 190)
    }

    func testShortTwiceRunningAtTheSameWeightBacksOff() {
        let sessions = [session(185, [8, 7, 6]), session(185, [8, 6, 6], on: earlier)]
        let next = ProgressionRule.next(target: 8, setCount: 3, sessions: sessions, step: 5)
        XCTAssertEqual(next, .backOff(to: 165, from: 185, target: 8))
    }

    /// Short now, but the time before was at a lighter weight: that was the
    /// first try at this one, not a stall.
    func testShortOnceAfterGoingUpIsNotAStall() {
        let sessions = [session(190, [8, 7, 6]), session(185, [8, 8, 8], on: earlier)]
        XCTAssertEqual(ProgressionRule.next(target: 8, setCount: 3, sessions: sessions, step: 5)?.weight, 190)
    }

    func testNothingHonestToSayIsNoSuggestion() {
        XCTAssertNil(ProgressionRule.next(target: 8, setCount: 3, sessions: [], step: 5))
        XCTAssertNil(ProgressionRule.next(target: 0, setCount: 3, sessions: [session(185, [8])], step: 5))
        // Bodyweight: no step to take.
        XCTAssertNil(ProgressionRule.next(target: 8, setCount: 3, sessions: [session(0, [10, 10, 10])], step: 5))
    }

    /// A pound weight stored as kilograms reads back a hair off; the next one
    /// is still a real plate pair.
    func testAConvertedWeightStepsCleanly() {
        let stored = WeightUnit.pounds.fromKilograms(WeightUnit.pounds.toKilograms(185))
        let next = ProgressionRule.next(target: 8, setCount: 1, sessions: [session(stored, [8])], step: 5)
        XCTAssertEqual(next?.weight, 190)
    }

    func testTheStepIsAPairOfTheSmallestPlateOwned() {
        let pounds = PlateSetup.standard(for: .pounds)
        XCTAssertEqual(ProgressionRule.step(unit: .pounds, bar: .barbell, setup: pounds), 5)
        var withChange = pounds
        withChange.set(pairs: 1, of: 1.25)
        XCTAssertEqual(ProgressionRule.step(unit: .pounds, bar: .barbell, setup: withChange), 2.5)
        XCTAssertEqual(ProgressionRule.step(unit: .kilograms, bar: .barbell,
                                            setup: PlateSetup.standard(for: .kilograms)), 2.5)
        // Off the bar the plates do not matter.
        XCTAssertEqual(ProgressionRule.step(unit: .pounds, bar: nil, setup: withChange), 5)
        XCTAssertEqual(ProgressionRule.step(unit: .kilograms, bar: nil, setup: pounds), 2.5)
    }

    func testTheLinesSayWhy() {
        XCTAssertTrue(ProgressionRule.line(.up(to: 190, from: 185, reps: 8, date: monday), unit: .pounds)
            .hasPrefix("Next: 190 lb. Every set reached 8 at 185 last time ("))
        XCTAssertTrue(ProgressionRule.line(.same(185, reps: [8, 8, 6], target: 8, date: monday), unit: .pounds)
            .hasPrefix("Next: 185 lb again. 8, 8, 6 at 185 last time ("))
        XCTAssertEqual(ProgressionRule.line(.backOff(to: 75, from: 82.5, target: 5), unit: .kilograms),
                       "Next: 75 kg. Short of 5 at 82.5 two sessions running, so back off and build up again.")
    }

    // MARK: - Drop sets and rest-pause are not working sets for this rule

    /// One prescribed set: pounds, reps, and its kind (nil is straight).
    private typealias Prescribed = (lb: Double, reps: Int, kind: SetKind?)

    private func defaults() throws -> UserDefaults {
        let suite = "progression-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    /// A lifter's own routine of one barbell lift, its set kinds written to
    /// `RoutineSetTypes` the way the routine editor writes them.
    private func routine(_ sets: [Prescribed], in context: ModelContext,
                         defaults: UserDefaults) throws -> Routine {
        let routine = Routine(name: "Push")
        let bench = RoutineExercise(name: "Bench Press", equipment: "Barbell", orderIndex: 0)
        bench.prescribedSets = sets.enumerated().map { i, set in
            RoutinePrescribedSet(orderIndex: i, targetWeightKg: WeightUnit.pounds.toKilograms(set.lb),
                                 targetReps: set.reps)
        }
        routine.exercises = [bench]
        context.insert(routine)
        try context.save()
        var types = RoutineSetTypes.load(from: defaults)
        for (prescribed, set) in zip(bench.orderedSets, sets) {
            types.setKind(set.kind, for: prescribed, in: bench)
        }
        types.save(to: defaults)
        return routine
    }

    /// Starts the routine on `date` through `startSession`, so the logged
    /// kinds are the ones a real session carries, then logs these reps.
    private func log(_ routine: Routine, on date: Date, reps: [Int]? = nil, lb: [Double]? = nil,
                     in context: ModelContext, defaults: UserDefaults) throws -> WorkoutDay {
        let day = routine.startSession(on: date, in: context, defaults: defaults)
        let sets = try XCTUnwrap(day.exercises.first).orderedSets
        for (i, set) in sets.enumerated() {
            if let reps { set.reps = reps[i] }
            if let lb { set.weightKg = WeightUnit.pounds.toKilograms(lb[i]) }
            set.completedAt = date
        }
        try context.save()
        return day
    }

    private func suggestion(for routine: Routine, today: WorkoutDay, after days: [WorkoutDay],
                            defaults: UserDefaults) throws -> ProgressionRule.Next? {
        let types = RoutineSetTypes.load(from: defaults)
        let target = try XCTUnwrap(ProgressionRule.target(
            of: try XCTUnwrap(routine.orderedExercises.first), setTypes: types))
        return ProgressionRule.next(
            target: target.reps, setCount: target.sets,
            sessions: ProgressionRule.sessions(of: try XCTUnwrap(today.exercises.first), in: days,
                                               unit: .pounds, setTypes: types),
            step: 5)
    }

    private let lastWeek = Calendar.current.date(byAdding: .day, value: -7, to: .now)!
    private let twoWeeksAgo = Calendar.current.date(byAdding: .day, value: -14, to: .now)!

    /// The routine asks for its straight sets: their reps and how many of
    /// them. A drop set's twelve is not the bench press's target.
    func testTheTargetIsTheStraightSets() throws {
        let context = ModelContext(LiftStore.makeContainer(inMemory: true))
        let defaults = try defaults()
        let routine = try routine([(185, 8, nil), (185, 8, nil), (135, 12, .drop), (95, 12, .drop)],
                                  in: context, defaults: defaults)
        XCTAssertEqual(ProgressionRule.target(of: try XCTUnwrap(routine.orderedExercises.first),
                                              setTypes: RoutineSetTypes.load(from: defaults)),
                       ProgressionRule.Target(reps: 8, sets: 2))
    }

    /// A routine with no set types reads exactly as it always did.
    func testARoutineWithoutSetTypesHasTheTargetItAlwaysHad() throws {
        let context = ModelContext(LiftStore.makeContainer(inMemory: true))
        let defaults = try defaults()
        let routine = try routine([(185, 8, nil), (185, 8, nil), (185, 10, nil)],
                                  in: context, defaults: defaults)
        XCTAssertEqual(ProgressionRule.target(of: try XCTUnwrap(routine.orderedExercises.first),
                                              setTypes: RoutineSetTypes()),
                       ProgressionRule.Target(reps: 10, sets: 3))
    }

    /// Two straight sets of eight reached, then two lighter drop sets: up.
    /// Counting the drops, the routine asked for four sets and two were at
    /// the top weight, so it never said up -- and said back off after two.
    func testTwoStraightAndTwoDropSetsGoesUp() throws {
        let context = ModelContext(LiftStore.makeContainer(inMemory: true))
        let defaults = try defaults()
        let routine = try routine([(185, 8, nil), (185, 8, nil), (135, 12, .drop), (95, 12, .drop)],
                                  in: context, defaults: defaults)
        let before = try log(routine, on: twoWeeksAgo, reps: [8, 8, 10, 9], in: context, defaults: defaults)
        let last = try log(routine, on: lastWeek, reps: [8, 8, 11, 10], in: context, defaults: defaults)
        let today = routine.startSession(on: .now, in: context, defaults: defaults)

        let next = try suggestion(for: routine, today: today, after: [last, before], defaults: defaults)
        XCTAssertEqual(next?.weight, 190)
        guard case .up = next else { return XCTFail("expected up, got \(String(describing: next))") }
    }

    /// Rest-pause sets stay at the top weight and take fewer reps by design.
    /// Read as working sets, they made every session short.
    func testRestPauseSetsAtTheTopWeightDoNotHoldItBack() throws {
        let context = ModelContext(LiftStore.makeContainer(inMemory: true))
        let defaults = try defaults()
        let routine = try routine([(185, 8, nil), (185, 8, nil), (185, 4, .restPause), (185, 3, .restPause)],
                                  in: context, defaults: defaults)
        let last = try log(routine, on: lastWeek, reps: [8, 8, 4, 2], in: context, defaults: defaults)
        let today = routine.startSession(on: .now, in: context, defaults: defaults)

        XCTAssertEqual(try suggestion(for: routine, today: today, after: [last], defaults: defaults)?.weight, 190)
    }

    /// Back-off asks whether the straight sets were short at that weight two
    /// sessions running. Drop sets the lifter kept at the top weight, short
    /// of the straight sets' reps as a drop set always is, are not a stall.
    func testBackOffIgnoresDropSets() throws {
        let context = ModelContext(LiftStore.makeContainer(inMemory: true))
        let defaults = try defaults()
        let routine = try routine([(185, 8, nil), (185, 8, nil), (135, 12, .drop), (95, 12, .drop)],
                                  in: context, defaults: defaults)
        // Two weeks ago: both straight sets got eight, and the drops were
        // done at 185 too, for five and four.
        let before = try log(routine, on: twoWeeksAgo, reps: [8, 8, 5, 4], lb: [185, 185, 185, 185],
                             in: context, defaults: defaults)
        // Last week: one straight set short.
        let last = try log(routine, on: lastWeek, reps: [8, 7, 12, 12], in: context, defaults: defaults)
        let today = routine.startSession(on: .now, in: context, defaults: defaults)

        let next = try suggestion(for: routine, today: today, after: [last, before], defaults: defaults)
        XCTAssertEqual(next, .same(185, reps: [8, 7], target: 8, date: last.date),
                       "short once at 185 after reaching it is the same again, not a back-off")
    }

    /// The straight sets short twice running still backs off, drops or not.
    func testShortStraightSetsTwiceRunningStillBackOff() throws {
        let context = ModelContext(LiftStore.makeContainer(inMemory: true))
        let defaults = try defaults()
        let routine = try routine([(185, 8, nil), (185, 8, nil), (135, 12, .drop), (95, 12, .drop)],
                                  in: context, defaults: defaults)
        let before = try log(routine, on: twoWeeksAgo, reps: [8, 6, 12, 12], in: context, defaults: defaults)
        let last = try log(routine, on: lastWeek, reps: [7, 6, 12, 12], in: context, defaults: defaults)
        let today = routine.startSession(on: .now, in: context, defaults: defaults)

        XCTAssertEqual(try suggestion(for: routine, today: today, after: [last, before], defaults: defaults),
                       .backOff(to: 165, from: 185, target: 8))
    }

    /// A top set and its drops, no straight set beyond the first: the rule
    /// reads it as the one-set routine it is, exactly as a one-set routine
    /// always read.
    func testATopSetWithDropsProgressesOnTheTopSet() throws {
        let context = ModelContext(LiftStore.makeContainer(inMemory: true))
        let defaults = try defaults()
        let routine = try routine([(225, 6, nil), (185, 8, .drop), (135, 10, .drop)],
                                  in: context, defaults: defaults)
        XCTAssertEqual(ProgressionRule.target(of: try XCTUnwrap(routine.orderedExercises.first),
                                              setTypes: RoutineSetTypes.load(from: defaults)),
                       ProgressionRule.Target(reps: 6, sets: 1))
        let last = try log(routine, on: lastWeek, reps: [6, 7, 8], in: context, defaults: defaults)
        let today = routine.startSession(on: .now, in: context, defaults: defaults)
        XCTAssertEqual(try suggestion(for: routine, today: today, after: [last], defaults: defaults)?.weight, 230)
    }

    /// "Use" fills the straight sets not done. A drop set keeps its lighter
    /// weight, and a rest-pause set its own.
    func testUseLeavesDropAndRestPauseSetsAlone() throws {
        let context = ModelContext(LiftStore.makeContainer(inMemory: true))
        let defaults = try defaults()
        let routine = try routine([(185, 8, nil), (185, 8, nil), (185, 8, nil), (135, 12, .drop), (185, 4, .restPause)],
                                  in: context, defaults: defaults)
        let today = routine.startSession(on: .now, in: context, defaults: defaults)
        let entry = try XCTUnwrap(today.exercises.first)
        let sets = entry.orderedSets
        sets[0].completedAt = .now

        let fill = ProgressionRule.setsToFill(in: entry, weight: 190, unit: .pounds,
                                              setTypes: RoutineSetTypes.load(from: defaults))
        XCTAssertEqual(fill.map(\.id), [sets[1].id, sets[2].id],
                       "the done set, the drop set and the rest-pause set are left as they are")
    }

    /// A day logged without set types fills every working set not done, as
    /// "Use" always did -- warm-ups still left out.
    func testUseOnADayWithoutSetTypesFillsAsBefore() throws {
        let entry = ExerciseEntry(exerciseRefID: "routine:\(UUID().uuidString)", name: "Bench Press",
                                  orderIndex: 0, equipment: "Barbell")
        let warmup = SetEntry(orderIndex: 0, weightKg: 40, reps: 10)
        warmup.isWarmup = true
        let a = SetEntry(orderIndex: 1, weightKg: 80, reps: 8)
        let b = SetEntry(orderIndex: 2, weightKg: 80, reps: 8)
        entry.sets = [warmup, a, b]
        XCTAssertEqual(ProgressionRule.setsToFill(in: entry, weight: 185, unit: .pounds,
                                                  setTypes: RoutineSetTypes()).map(\.id),
                       [a.id, b.id])
    }
}
