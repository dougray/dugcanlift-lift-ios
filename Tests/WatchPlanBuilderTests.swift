import XCTest
import SwiftData
import LiftCore
@testable import Lift

/// What the phone decides to send the watch: which plan today has, what a
/// partial prescription becomes on the wire, where "last time's actual"
/// comes from, and which revision a push goes out under.
///
/// These are the rules the guided session stands on, and none of them lives
/// in a view — a rule in a view's `@State` cannot be tested, and this one
/// decides what a lifter is told to lift.
final class WatchPlanBuilderTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "WatchPlanBuilderTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    @MainActor
    private func makeContext() -> ModelContext {
        ModelContext(LiftStore.makeContainer(inMemory: true))
    }

    @MainActor
    @discardableResult
    private func insertRoutine(
        named name: String,
        in context: ModelContext,
        sets: [RoutinePrescribedSet] = [RoutinePrescribedSet(orderIndex: 0, targetWeightKg: 100, targetReps: 5)],
        exerciseName: String = "Bench Press",
        equipment: String = "barbell"
    ) -> Routine {
        let routine = Routine(name: name)
        let exercise = RoutineExercise(name: exerciseName, equipment: equipment, orderIndex: 0)
        exercise.prescribedSets = sets
        routine.exercises = [exercise]
        context.insert(routine)
        try? context.save()
        return routine
    }

    // MARK: - Which plan today has

    @MainActor
    func testNoRoutineAndNoScheduledSessionMeansNoPlan() {
        let context = makeContext()
        XCTAssertNil(WatchPlanBuilder.todaysPlan(in: context, defaults: defaults))
    }

    @MainActor
    func testACoachScheduledSessionForTodayIsTodaysPlan() throws {
        let context = makeContext()
        let routine = insertRoutine(named: "Lower A", in: context)
        context.insert(ScheduledSession(routineID: routine.id, routineName: routine.name, scheduledFor: .now))
        try context.save()

        let pushable = try XCTUnwrap(WatchPlanBuilder.todaysPlan(in: context, defaults: defaults))
        XCTAssertEqual(pushable.id, routine.id)
        XCTAssertEqual(pushable.plan.name, "Lower A")
        XCTAssertEqual(pushable.plan.source, .coachPlan)
        XCTAssertEqual(pushable.plan.scheduledFor, DayKey.today)
    }

    @MainActor
    func testACoachSessionScheduledForAnotherDayIsNotTodaysPlan() throws {
        let context = makeContext()
        let routine = insertRoutine(named: "Lower A", in: context)
        let tomorrow = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: 1, to: .now))
        context.insert(ScheduledSession(routineID: routine.id, routineName: routine.name, scheduledFor: tomorrow))
        try context.save()

        XCTAssertNil(WatchPlanBuilder.todaysPlan(in: context, defaults: defaults))
    }

    @MainActor
    func testARoutineSentByHandWinsOverACoachSession() throws {
        let context = makeContext()
        let coachRoutine = insertRoutine(named: "Coach Lower A", in: context)
        let mine = insertRoutine(named: "My Upper A", in: context)
        context.insert(ScheduledSession(routineID: coachRoutine.id, routineName: coachRoutine.name, scheduledFor: .now))
        try context.save()

        WatchPlanPin.save(routineID: mine.id, to: defaults)

        let pushable = try XCTUnwrap(WatchPlanBuilder.todaysPlan(in: context, defaults: defaults))
        XCTAssertEqual(pushable.plan.name, "My Upper A")
        XCTAssertEqual(pushable.plan.source, .routine)
    }

    @MainActor
    func testYesterdaysPinDoesNotFollowIntoToday() throws {
        let context = makeContext()
        let mine = insertRoutine(named: "My Upper A", in: context)
        let yesterday = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: -1, to: .now))
        WatchPlanPin.save(routineID: mine.id, on: yesterday, to: defaults)

        // The lifter said "run this today", not "run this from now on".
        XCTAssertNil(WatchPlanBuilder.todaysPlan(in: context, defaults: defaults))
    }

    // MARK: - Prescriptions

    @MainActor
    func testEveryPrescribedFieldIsOptionalAndBlankStaysBlank() throws {
        let context = makeContext()
        let routine = insertRoutine(
            named: "Upper A",
            in: context,
            sets: [
                // "[null, 5]" — five reps, you pick the weight.
                RoutinePrescribedSet(orderIndex: 0, targetWeightKg: nil, targetReps: 5),
                RoutinePrescribedSet(orderIndex: 1, targetWeightKg: 60, targetReps: nil, targetRPE: 7)
            ]
        )
        WatchPlanPin.save(routineID: routine.id, to: defaults)

        let plan = try XCTUnwrap(WatchPlanBuilder.todaysPlan(in: context, defaults: defaults)).plan
        let sets = try XCTUnwrap(plan.exercises.first?.sets)

        XCTAssertNil(sets[0].weightKg)     // not 0
        XCTAssertEqual(sets[0].reps, 5)
        XCTAssertNil(sets[0].rpe)
        XCTAssertEqual(sets[1].weightKg, 60)
        XCTAssertNil(sets[1].reps)         // not 0
        XCTAssertEqual(sets[1].rpe, 7)
    }

    @MainActor
    func testTargetWeightTravelsInKilogramsUnconverted() throws {
        // `RoutinePrescribedSet.targetWeightKg` is kilograms and the wire
        // field is `weightKg`. A conversion anywhere on this path would be
        // silent and 2.2x wrong on someone's wrist.
        let context = makeContext()
        let routine = insertRoutine(
            named: "Upper A", in: context,
            sets: [RoutinePrescribedSet(orderIndex: 0, targetWeightKg: 83.9146, targetReps: 5)]
        )
        WatchPlanPin.save(routineID: routine.id, to: defaults)

        let plan = try XCTUnwrap(WatchPlanBuilder.todaysPlan(in: context, defaults: defaults)).plan
        XCTAssertEqual(try XCTUnwrap(plan.exercises.first?.sets.first?.weightKg), 83.9146, accuracy: 0.0001)
    }

    @MainActor
    func testRestSecondsRideOnEverySetAndAreOmittedWhenThereIsNone() throws {
        let context = makeContext()
        let routine = insertRoutine(named: "Upper A", in: context)
        WatchPlanPin.save(routineID: routine.id, to: defaults)

        let withRest = try XCTUnwrap(
            WatchPlanBuilder.todaysPlan(in: context, restSeconds: 120, defaults: defaults)
        ).plan
        XCTAssertEqual(withRest.exercises.first?.sets.first?.restSeconds, 120)

        let without = try XCTUnwrap(
            WatchPlanBuilder.todaysPlan(in: context, restSeconds: nil, defaults: defaults)
        ).plan
        // Absent, so the watch falls back to its own default — which is not
        // the same as being told to rest for zero seconds.
        XCTAssertNil(without.exercises.first?.sets.first?.restSeconds)
    }

    @MainActor
    func testEquipmentIsOmittedRatherThanSentEmpty() throws {
        let context = makeContext()
        let routine = insertRoutine(named: "Upper A", in: context, exerciseName: "Chin Up", equipment: "")
        WatchPlanPin.save(routineID: routine.id, to: defaults)

        let plan = try XCTUnwrap(WatchPlanBuilder.todaysPlan(in: context, defaults: defaults)).plan
        XCTAssertNil(plan.exercises.first?.equipment)
    }

    // MARK: - Last time's actual

    @MainActor
    private func loggedDay(
        daysAgo: Int,
        exercise: String,
        equipment: String?,
        sets: [SetEntry],
        in context: ModelContext
    ) {
        let date = Calendar.current.date(byAdding: .day, value: -daysAgo, to: .now)!
        let day = WorkoutDay(date: date, name: "Day")
        let entry = ExerciseEntry(exerciseRefID: "x", name: exercise, orderIndex: 0, equipment: equipment)
        entry.sets = sets
        day.exercises = [entry]
        context.insert(day)
        try? context.save()
    }

    @MainActor
    func testLastPerformedComesFromTheMostRecentDayThatHasTheExercise() throws {
        let context = makeContext()
        loggedDay(daysAgo: 14, exercise: "Bench Press", equipment: "barbell",
                  sets: [SetEntry(orderIndex: 0, weightKg: 80, reps: 5, rpe: 7)], in: context)
        loggedDay(daysAgo: 7, exercise: "Bench Press", equipment: "barbell",
                  sets: [SetEntry(orderIndex: 0, weightKg: 82.5, reps: 5, rpe: 8)], in: context)
        let routine = insertRoutine(named: "Upper A", in: context)
        WatchPlanPin.save(routineID: routine.id, to: defaults)

        let plan = try XCTUnwrap(WatchPlanBuilder.todaysPlan(in: context, defaults: defaults)).plan
        let last = try XCTUnwrap(plan.exercises.first?.lastPerformed)
        XCTAssertEqual(last.weightKg, 82.5)
        XCTAssertEqual(last.reps, 5)
        XCTAssertEqual(last.rpe, 8)
    }

    @MainActor
    func testLastPerformedIsMatchedOnNameAndEquipmentTogether() throws {
        // A cable pulldown and a machine pulldown are not the same lift.
        let context = makeContext()
        loggedDay(daysAgo: 3, exercise: "Lat Pulldown", equipment: "machine",
                  sets: [SetEntry(orderIndex: 0, weightKg: 70, reps: 10)], in: context)
        let routine = insertRoutine(named: "Upper A", in: context,
                                    exerciseName: "Lat Pulldown", equipment: "cable")
        WatchPlanPin.save(routineID: routine.id, to: defaults)

        let plan = try XCTUnwrap(WatchPlanBuilder.todaysPlan(in: context, defaults: defaults)).plan
        XCTAssertNil(plan.exercises.first?.lastPerformed)
    }

    @MainActor
    func testLastPerformedIgnoresCaseAndSurroundingSpace() {
        let day = WorkoutDay(date: .now.addingTimeInterval(-86_400), name: "Day")
        let entry = ExerciseEntry(exerciseRefID: "x", name: "bench press", orderIndex: 0, equipment: "Barbell")
        entry.sets = [SetEntry(orderIndex: 0, weightKg: 100, reps: 3)]
        day.exercises = [entry]

        let last = WatchPlanBuilder.lastPerformed(
            name: "  Bench Press ", equipment: "barbell", in: [day]
        )
        XCTAssertEqual(last?.weightKg, 100)
        XCTAssertEqual(last?.reps, 3)
    }

    @MainActor
    func testLastPerformedSkipsWarmupsAndNeverReportsAZero() {
        let day = WorkoutDay(date: .now.addingTimeInterval(-86_400), name: "Day")
        let entry = ExerciseEntry(exerciseRefID: "x", name: "Squat", orderIndex: 0, equipment: "barbell")
        entry.sets = [
            SetEntry(orderIndex: 0, weightKg: 60, reps: 5, isWarmup: true),
            // Reps with no weight: a real set, and its weight must travel as
            // nothing rather than as 0.
            SetEntry(orderIndex: 1, weightKg: 0, reps: 12)
        ]
        day.exercises = [entry]

        let last = WatchPlanBuilder.lastPerformed(name: "Squat", equipment: "barbell", in: [day])
        XCTAssertNil(last?.weightKg)
        XCTAssertEqual(last?.reps, 12)
    }

    @MainActor
    func testLastPerformedExcludesTodayItself() {
        // Sets already logged today are the session in progress, not "last
        // time" — showing them would make the reference line chase itself.
        let today = WorkoutDay(date: .now, name: "Day")
        let entry = ExerciseEntry(exerciseRefID: "x", name: "Squat", orderIndex: 0, equipment: "barbell")
        entry.sets = [SetEntry(orderIndex: 0, weightKg: 140, reps: 1)]
        today.exercises = [entry]

        XCTAssertNil(WatchPlanBuilder.lastPerformed(
            name: "Squat", equipment: "barbell", in: [today], excludingDayKey: DayKey.today
        ))
    }

    // MARK: - Revisions

    func testRevisionStartsAtOneAndOnlyRisesWhenTheContentChanges() {
        var revisions = WatchPlanRevisions()
        let id = UUID()
        let plan = WorkoutPlan(name: "Upper A", source: .routine, scheduledFor: "2026-09-20",
                               exercises: [PlanExercise(name: "Row", equipment: nil, note: nil,
                                                        sets: [PrescribedSet(reps: 8)],
                                                        lastPerformed: nil)])
        var changed = plan
        changed.exercises[0].sets[0].reps = 10

        let first = revisions.revision(for: id, contentHash: WatchPlanRevisions.contentHash(of: plan))
        let again = revisions.revision(for: id, contentHash: WatchPlanRevisions.contentHash(of: plan))
        let afterEdit = revisions.revision(for: id, contentHash: WatchPlanRevisions.contentHash(of: changed))

        XCTAssertEqual(first, 1)          // the schema's minimum
        XCTAssertEqual(again, 1)          // an unchanged plan is not a new one
        XCTAssertEqual(afterEdit, 2)
    }

    func testRevisionsAreKeptPerPlan() {
        var revisions = WatchPlanRevisions()
        let upper = UUID(), lower = UUID()
        _ = revisions.revision(for: upper, contentHash: "a")
        _ = revisions.revision(for: upper, contentHash: "b")
        XCTAssertEqual(revisions.revision(for: lower, contentHash: "c"), 1)
        XCTAssertEqual(revisions.revision(for: upper, contentHash: "b"), 2)
    }

    func testRevisionsSurviveARelaunch() {
        var revisions = WatchPlanRevisions()
        let id = UUID()
        _ = revisions.revision(for: id, contentHash: "a")
        _ = revisions.revision(for: id, contentHash: "b")
        revisions.save(to: defaults)

        var reloaded = WatchPlanRevisions.load(from: defaults)
        // Unchanged content after a relaunch must not look like a new plan,
        // or every launch would re-push what the watch already has.
        XCTAssertEqual(reloaded.revision(for: id, contentHash: "b"), 2)
    }

    func testContentHashIsStableAcrossEncodings() {
        let plan = WorkoutPlan(name: "Upper A", source: .routine, scheduledFor: "2026-09-20",
                               exercises: [PlanExercise(name: "Row", equipment: "barbell", note: "tempo",
                                                        sets: [PrescribedSet(weightKg: 60, reps: 8)],
                                                        lastPerformed: LastPerformed(weightKg: 60, reps: 8))])
        XCTAssertEqual(WatchPlanRevisions.contentHash(of: plan), WatchPlanRevisions.contentHash(of: plan))
    }

    // MARK: - The rest default

    func testAPhoneThatHasNeverOpenedSettingsStillSendsARest() {
        // Never-set is the normal case — the Settings stepper's @AppStorage
        // default only reaches disk once someone opens that screen — and
        // reading it as zero would push every set with no rest at all, so
        // rest would never start on its own for anyone who had not been
        // into Settings.
        XCTAssertNil(defaults.object(forKey: WatchPlanSettings.restSecondsKey))
        XCTAssertEqual(WatchPlanSettings.resolvedRestSeconds(in: defaults), 90)
    }

    func testAStoredRestIsUsedAndAStoredZeroMeansSayNothing() {
        defaults.set(150, forKey: WatchPlanSettings.restSecondsKey)
        XCTAssertEqual(WatchPlanSettings.resolvedRestSeconds(in: defaults), 150)

        defaults.set(0, forKey: WatchPlanSettings.restSecondsKey)
        XCTAssertNil(WatchPlanSettings.resolvedRestSeconds(in: defaults))
    }

    // MARK: - Heart rate landing

    @MainActor
    func testSessionFinishedHeartRateIsRecorded() async {
        let context = makeContext()
        let receiver = WatchSyncReceiver(context: context)
        let id = UUID()
        let handled = await receiver.handle(SyncEnvelope(
            event: .sessionFinished, workoutID: id, revision: 3,
            updatedAt: .now, origin: .watchOS,
            heartRate: SessionHeartRate(averageBpm: 131, maxBpm: 168)
        ))

        XCTAssertTrue(handled)
        let stored = WatchSessionHeartRateStore.latest()
        XCTAssertEqual(stored?.workoutID, id)
        XCTAssertEqual(stored?.averageBpm, 131)
        XCTAssertEqual(stored?.maxBpm, 168)
    }

    @MainActor
    func testSessionFinishedWithoutHeartRateIsStillNotAnError() async {
        let context = makeContext()
        let receiver = WatchSyncReceiver(context: context)
        // Unhandled, but harmless: a watch that recorded no heart rate (or an
        // older build that does not send any) must not be treated as broken.
        let handled = await receiver.handle(SyncEnvelope(
            event: .sessionFinished, workoutID: UUID(), revision: 1,
            updatedAt: .now, origin: .watchOS
        ))
        XCTAssertFalse(handled)
    }
}
