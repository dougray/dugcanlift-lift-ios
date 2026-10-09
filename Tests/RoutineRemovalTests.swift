import XCTest
import SwiftData
import LiftCore
@testable import Lift

/// Deleting a routine: what goes, what must not, and the sentence asked first.
///
/// The half that matters is what stays. A template is a convenience; the
/// workouts logged from it are the record, and nothing here may touch them.
@MainActor
final class RoutineRemovalTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        ModelContext(LiftStore.makeContainer(inMemory: true))
    }

    private func defaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let suite = "routine-removal-\(UUID().uuidString)"
        guard let store = UserDefaults(suiteName: suite) else { return XCTFail("no suite") }
        defer { store.removePersistentDomain(forName: suite) }
        try body(store)
    }

    @discardableResult
    private func makeRoutine(_ name: String, in context: ModelContext) -> Routine {
        let routine = Routine(name: name)
        let press = RoutineExercise(name: "Bench Press", equipment: "Barbell", orderIndex: 0)
        press.prescribedSets = [
            RoutinePrescribedSet(orderIndex: 0, targetWeightKg: 80, targetReps: 5),
            RoutinePrescribedSet(orderIndex: 1, targetWeightKg: 80, targetReps: 5)
        ]
        routine.exercises = [press]
        context.insert(routine)
        try? context.save()
        return routine
    }

    private func count<T: PersistentModel>(_ type: T.Type, in context: ModelContext) -> Int {
        (try? context.fetchCount(FetchDescriptor<T>())) ?? 0
    }

    // MARK: - What goes

    func testDeletingARoutineTakesItsExercisesAndPrescribedSets() throws {
        let context = try makeContext()
        let routine = makeRoutine("Push", in: context)
        XCTAssertEqual(count(RoutineExercise.self, in: context), 1)
        XCTAssertEqual(count(RoutinePrescribedSet.self, in: context), 2)

        defaults { store in
            XCTAssertTrue(RoutineRemoval.remove(routine, in: context, defaults: store))
        }

        XCTAssertEqual(count(Routine.self, in: context), 0)
        XCTAssertEqual(count(RoutineExercise.self, in: context), 0)
        XCTAssertEqual(count(RoutinePrescribedSet.self, in: context), 0)
    }

    /// No SwiftData cascade reaches a `ScheduledSession` — it holds
    /// `routineID` as a plain value. Left behind, it draws "Coach scheduled:
    /// Push" on its day forever and does nothing when tapped.
    func testDeletingARoutineTakesTheDaysACoachBookedItOn() throws {
        let context = try makeContext()
        let routine = makeRoutine("Push", in: context)
        let other = makeRoutine("Pull", in: context)
        for day in 0..<3 {
            context.insert(ScheduledSession(routineID: routine.id, routineName: "Push",
                                            scheduledFor: Date(timeIntervalSince1970: 1_757_000_000 + Double(day) * 86_400)))
        }
        context.insert(ScheduledSession(routineID: other.id, routineName: "Pull",
                                        scheduledFor: Date(timeIntervalSince1970: 1_757_000_000)))
        try context.save()

        defaults { store in
            XCTAssertTrue(RoutineRemoval.remove(routine, in: context, defaults: store))
        }

        let left = try context.fetch(FetchDescriptor<ScheduledSession>())
        XCTAssertEqual(left.map(\.routineName), ["Pull"])
    }

    func testDeletingThePinnedRoutineClearsTheWatchPin() throws {
        let context = try makeContext()
        let routine = makeRoutine("Push", in: context)

        defaults { store in
            WatchPlanPin.save(routineID: routine.id, to: store)
            XCTAssertTrue(RoutineRemoval.remove(routine, in: context, defaults: store))
            XCTAssertNil(WatchPlanPin.load(from: store))
        }
    }

    /// A pin at some other routine is somebody else's plan for today.
    func testDeletingARoutineLeavesAPinAtADifferentOneAlone() throws {
        let context = try makeContext()
        let routine = makeRoutine("Push", in: context)
        let other = makeRoutine("Pull", in: context)

        defaults { store in
            WatchPlanPin.save(routineID: other.id, to: store)
            XCTAssertTrue(RoutineRemoval.remove(routine, in: context, defaults: store))
            XCTAssertEqual(WatchPlanPin.load(from: store)?.routineID, other.id)
        }
    }

    /// `PlanSides.eachSide` and `.sides` are keyed by ids that stop existing
    /// with the rows, so they go. Another routine's keep theirs.
    func testDeletingARoutineSweepsItsPrescriptionSides() throws {
        let context = try makeContext()
        let routine = makeRoutine("Push", in: context)
        let other = makeRoutine("Pull", in: context)
        let mine = routine.orderedExercises[0]
        let theirs = other.orderedExercises[0]

        defaults { store in
            var sides = PlanSides()
            sides.eachSide = [mine.id, theirs.id]
            sides.sides = [mine.orderedSets[0].id: .left, theirs.orderedSets[0].id: .right]
            sides.save(to: store)

            XCTAssertTrue(RoutineRemoval.remove(routine, in: context, defaults: store))

            let after = PlanSides.load(from: store)
            XCTAssertEqual(after.eachSide, [theirs.id])
            XCTAssertEqual(after.sides, [theirs.orderedSets[0].id: .right])
        }
    }

    // MARK: - What stays

    /// The whole reason a logged entry snapshots its name and numbers. A
    /// workout is a record of a day; tidying a template away months later
    /// must not edit it.
    func testWorkoutsAlreadyLoggedFromARoutineSurviveIt() throws {
        let context = try makeContext()
        let routine = makeRoutine("Push", in: context)
        let day = routine.startSession(on: Date(timeIntervalSince1970: 1_757_000_000), in: context)
        try context.save()
        let entryNames = day.orderedExercises.map(\.name)
        let setCount = day.orderedExercises.reduce(0) { $0 + $1.orderedSets.count }
        XCTAssertFalse(entryNames.isEmpty)
        XCTAssertGreaterThan(setCount, 0)

        defaults { store in
            XCTAssertTrue(RoutineRemoval.remove(routine, in: context, defaults: store))
        }

        let days = try context.fetch(FetchDescriptor<WorkoutDay>())
        XCTAssertEqual(days.count, 1)
        XCTAssertEqual(days[0].name, "Push")
        XCTAssertEqual(days[0].orderedExercises.map(\.name), entryNames)
        XCTAssertEqual(days[0].orderedExercises.reduce(0) { $0 + $1.orderedSets.count }, setCount)
    }

    /// `PlanSides.logged` is keyed by `ExerciseEntry.id` and is deliberately a
    /// copy rather than a link back, "so the targets survive the routine being
    /// edited or deleted".
    func testASessionsOwnPrescriptionSurvivesTheRoutine() throws {
        let context = try makeContext()
        let routine = makeRoutine("Push", in: context)

        defaults { store in
            var sides = PlanSides()
            sides.eachSide = [routine.orderedExercises[0].id]
            sides.save(to: store)

            let day = routine.startSession(on: Date(timeIntervalSince1970: 1_757_000_000),
                                           in: context, defaults: store)
            try? context.save()
            let entryID = day.orderedExercises[0].id
            XCTAssertNotNil(PlanSides.prescription(for: entryID, in: store))

            XCTAssertTrue(RoutineRemoval.remove(routine, in: context, defaults: store))

            XCTAssertNotNil(PlanSides.prescription(for: entryID, in: store),
                            "a logged session's own targets are not the routine's to take")
        }
    }

    func testDeletingARoutineLeavesEveryOtherRoutineAlone() throws {
        let context = try makeContext()
        let routine = makeRoutine("Push", in: context)
        makeRoutine("Pull", in: context)
        makeRoutine("Legs", in: context)

        defaults { store in
            XCTAssertTrue(RoutineRemoval.remove(routine, in: context, defaults: store))
        }

        let left = try context.fetch(FetchDescriptor<Routine>())
        XCTAssertEqual(Set(left.map(\.name)), ["Pull", "Legs"])
        XCTAssertEqual(count(RoutineExercise.self, in: context), 2)
    }

    // MARK: - The sentence asked first

    /// What stays is always said. A count of zero is left out entirely rather
    /// than said as "0 days" — the distinction Coach's confirmation makes.
    func testTheConfirmationAlwaysSaysWhatStays() throws {
        let plain = RoutineRemoval.warning(RoutineRemoval.Summary())
        XCTAssertEqual(plain, "Its exercises and target sets go with it. "
                       + "Workouts you have already logged from it stay.")
        XCTAssertFalse(plain.contains("0"))
        XCTAssertFalse(plain.contains("watch"))
    }

    func testTheConfirmationCountsTheBookedDaysAndSaysOneAsAWord() throws {
        XCTAssertTrue(RoutineRemoval.warning(.init(scheduledDays: 1))
            .hasSuffix("One day your coach scheduled it for goes too."))
        XCTAssertTrue(RoutineRemoval.warning(.init(scheduledDays: 4))
            .hasSuffix("4 days your coach scheduled it for go too."))
    }

    func testTheConfirmationSaysWhenItIsTodaysWatchPlan() throws {
        let both = RoutineRemoval.warning(.init(scheduledDays: 2, isPinnedToWatch: true))
        XCTAssertTrue(both.contains("2 days your coach scheduled it for go too."))
        XCTAssertTrue(both.hasSuffix("It is today's watch plan, so that is cleared too."))
    }

    func testTheSummaryCountsBeforeAnythingIsTouched() throws {
        let context = try makeContext()
        let routine = makeRoutine("Push", in: context)
        context.insert(ScheduledSession(routineID: routine.id, routineName: "Push",
                                        scheduledFor: Date(timeIntervalSince1970: 1_757_000_000)))
        context.insert(ScheduledSession(routineID: routine.id, routineName: "Push",
                                        scheduledFor: Date(timeIntervalSince1970: 1_757_086_400)))
        try context.save()

        defaults { store in
            WatchPlanPin.save(routineID: routine.id, to: store)
            XCTAssertEqual(RoutineRemoval.summary(for: routine, in: context, defaults: store),
                           RoutineRemoval.Summary(scheduledDays: 2, isPinnedToWatch: true))
            // Counting changed nothing.
            XCTAssertEqual(count(Routine.self, in: context), 1)
            XCTAssertEqual(count(ScheduledSession.self, in: context), 2)
        }
    }
}
