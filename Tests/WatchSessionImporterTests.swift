import XCTest
import SwiftData
import LiftCore
import LiftSync
@testable import Lift

/// Storing a workout the watch logged, and what happens when this phone and
/// that watch disagree about it.
///
/// `WatchSessionImporter` is where those rules live — out of
/// `WatchSyncReceiver`, which cannot be driven without a `WCSession`, for
/// the reason `LiftProgression` is out of a view: this decides what happens
/// to somebody's training.
@MainActor
final class WatchSessionImporterTests: XCTestCase {

    private func makeContext() -> ModelContext {
        ModelContext(LiftStore.makeContainer(inMemory: true))
    }

    /// Its own suite per test: the receipts and the per-side choices this
    /// writes must never land in the test host's real defaults.
    private func isolatedDefaults(_ name: String = #function) -> UserDefaults {
        let suite = "WatchSessionImporterTests.\(name)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    // 2026-09-20 09:00 UTC, and the phone's "now" an hour later.
    private let started = Date(timeIntervalSince1970: 1_789_891_200)
    private let now = Date(timeIntervalSince1970: 1_789_894_800)

    private func session(
        name: String = "Upper A",
        performedOn: String? = nil,
        exercises: [PerformedExercise]? = nil
    ) -> FinishedSession {
        FinishedSession(
            name: name,
            focus: "powerlifting",
            performedOn: performedOn ?? DayKey.make(from: started),
            startedAt: started,
            finishedAt: now,
            exercises: exercises ?? [
                PerformedExercise(
                    name: "Bench Press", equipment: "barbell",
                    sets: [
                        PerformedSet(weightKg: 60, reps: 8, isWarmup: true, completedAt: started),
                        PerformedSet(weightKg: 83.9146, reps: 5, rpe: 8, completedAt: now)
                    ]
                )
            ]
        )
    }

    private func envelope(_ session: FinishedSession, id: UUID = UUID(),
                          revision: Int = 2) -> SyncEnvelope {
        SyncEnvelope(event: .sessionFinished, workoutID: id, revision: revision,
                     updatedAt: now, origin: .watchOS, session: session)
    }

    private func days(in context: ModelContext) throws -> [WorkoutDay] {
        try context.fetch(FetchDescriptor<WorkoutDay>())
    }

    // MARK: - A session this phone has never seen

    func testAWatchSessionBecomesAnOrdinaryWorkout() throws {
        let context = makeContext()
        let defaults = isolatedDefaults()

        let outcome = WatchSessionImporter.apply(envelope(session()), in: context,
                                                 now: now, defaults: defaults)

        XCTAssertEqual(outcome, .stored)
        let day = try XCTUnwrap(try days(in: context).first)
        XCTAssertEqual(day.dayKey, DayKey.make(from: started))
        XCTAssertEqual(day.name, "Upper A")
        XCTAssertEqual(day.focus, .powerlifting)

        let exercise = try XCTUnwrap(day.orderedExercises.first)
        XCTAssertEqual(exercise.name, "Bench Press")
        XCTAssertEqual(exercise.equipment, "barbell")
        XCTAssertEqual(exercise.orderedSets.map(\.weightKg), [60, 83.9146])
        XCTAssertEqual(exercise.orderedSets.map(\.reps), [8, 5])
        XCTAssertEqual(exercise.orderedSets.map(\.rpe), [nil, 8])
        XCTAssertEqual(exercise.orderedSets.map(\.isWarmup), [true, false])
        XCTAssertEqual(exercise.orderedSets.map(\.completedAt), [started, now])
        // Warmups do not count towards volume, here as everywhere else.
        XCTAssertEqual(day.totalVolumeKg, 83.9146 * 5, accuracy: 0.0001)
    }

    /// Kilograms on the wire, kilograms in the store. A conversion here
    /// would be silent and 2.2x wrong.
    func testNothingConvertsTheWeight() throws {
        let context = makeContext()
        WatchSessionImporter.apply(envelope(session()), in: context, now: now,
                                   defaults: isolatedDefaults())

        let set = try XCTUnwrap(try days(in: context).first?.orderedExercises.first?
            .orderedSets.last)
        XCTAssertEqual(set.weightKg, 83.9146)
    }

    /// An envelope from a watch build that predates the payload is what it
    /// always was: a notification, with nothing to store.
    func testASessionFinishedWithNoPayloadStoresNothing() throws {
        let context = makeContext()
        let bare = SyncEnvelope(event: .sessionFinished, workoutID: UUID(), revision: 1,
                                updatedAt: now, origin: .watchOS)

        let outcome = WatchSessionImporter.apply(bare, in: context, now: now,
                                                 defaults: isolatedDefaults())

        XCTAssertEqual(outcome, .nothingToStore)
        XCTAssertTrue(try days(in: context).isEmpty)
    }

    // MARK: - Sides

    /// The reason this work is based on the per-side branch: a limb logged
    /// on the wrist is the same limb on the phone.
    func testPerSideSetsKeepTheirSides() throws {
        let context = makeContext()
        let defaults = isolatedDefaults()
        let perSide = session(exercises: [
            PerformedExercise(name: "Bulgarian Split Squat", equipment: "dumbbell", sets: [
                PerformedSet(weightKg: 30, reps: 8, rpe: 8, side: .left),
                PerformedSet(weightKg: 30, reps: 7, rpe: 9, side: .right),
                PerformedSet(weightKg: 30, reps: 7, side: .left),
                PerformedSet(weightKg: 30, reps: 7, side: .right)
            ])
        ])

        WatchSessionImporter.apply(envelope(perSide), in: context, now: now, defaults: defaults)

        let exercise = try XCTUnwrap(try days(in: context).first?.orderedExercises.first)
        XCTAssertEqual(exercise.orderedSets.map(\.side), [.left, .right, .left, .right])
        XCTAssertEqual(exercise.perSideCountLabel, "L 2 · R 2")
        // A lift logged one limb at a time on the watch is offered one limb
        // at a time here, unless the lifter has already said otherwise.
        XCTAssertEqual(
            PerSideLogging.isOn(ExerciseKey.make(name: "Bulgarian Split Squat",
                                                 equipment: "dumbbell"),
                                in: defaults.string(forKey: PerSideLogging.storageKey) ?? "{}"),
            true
        )
    }

    /// "A 'no' on a name it says yes to must stick" — including against
    /// this. The sets still keep their sides; only the phone's own set row
    /// is left as the lifter set it.
    func testAnExplicitNoToPerSideLoggingIsNotOverruled() throws {
        let context = makeContext()
        let defaults = isolatedDefaults()
        let key = ExerciseKey.make(name: "Bulgarian Split Squat", equipment: "dumbbell")
        defaults.set(PerSideLogging.setting(false, for: key, in: "{}"),
                     forKey: PerSideLogging.storageKey)

        WatchSessionImporter.apply(envelope(session(exercises: [
            PerformedExercise(name: "Bulgarian Split Squat", equipment: "dumbbell",
                              sets: [PerformedSet(weightKg: 30, reps: 8, side: .left)])
        ])), in: context, now: now, defaults: defaults)

        XCTAssertEqual(
            PerSideLogging.isOn(key, in: defaults.string(forKey: PerSideLogging.storageKey) ?? "{}"),
            false
        )
        XCTAssertEqual(try days(in: context).first?.orderedExercises.first?
            .orderedSets.first?.side, .left)
    }

    /// A session with no sides in it is stored exactly as it would have been
    /// before any of this existed: absent is both, and nothing is guessed.
    func testASessionWithNoSidesIsStoredWithNone() throws {
        let context = makeContext()
        let defaults = isolatedDefaults()

        WatchSessionImporter.apply(envelope(session()), in: context, now: now, defaults: defaults)

        XCTAssertEqual(try days(in: context).first?.orderedExercises.first?
            .orderedSets.compactMap(\.side), [])
        XCTAssertNil(defaults.string(forKey: PerSideLogging.storageKey))
    }

    // MARK: - The same session twice

    /// A resend, or the queued copy of one that already arrived. Storing it
    /// again would double every set.
    func testTheSameSessionArrivingTwiceIsStoredOnce() throws {
        let context = makeContext()
        let defaults = isolatedDefaults()
        let sent = envelope(session())

        XCTAssertEqual(WatchSessionImporter.apply(sent, in: context, now: now,
                                                  defaults: defaults), .stored)
        XCTAssertEqual(WatchSessionImporter.apply(sent, in: context, now: now,
                                                  defaults: defaults), .duplicate)

        XCTAssertEqual(try days(in: context).count, 1)
        XCTAssertEqual(try days(in: context).first?.totalSetCount, 2)
    }

    /// Deliveries are not ordered, so the older revision can arrive last. It
    /// is ignored rather than undoing the newer one.
    func testAnOlderRevisionArrivingLateIsIgnored() throws {
        let context = makeContext()
        let defaults = isolatedDefaults()
        let id = UUID()

        WatchSessionImporter.apply(
            envelope(session(name: "Upper A (edited)"), id: id, revision: 3),
            in: context, now: now, defaults: defaults)
        let outcome = WatchSessionImporter.apply(
            envelope(session(name: "Upper A"), id: id, revision: 2),
            in: context, now: now, defaults: defaults)

        XCTAssertEqual(outcome, .duplicate)
        XCTAssertEqual(try days(in: context).first?.name, "Upper A (edited)")
    }

    /// Two different sessions on the same day are two blocks of exercises on
    /// it, not one replacing the other: only the id makes a repeat.
    func testTwoDifferentSessionsOnOneDayBothLand() throws {
        let context = makeContext()
        let defaults = isolatedDefaults()

        WatchSessionImporter.apply(envelope(session()), in: context, now: now, defaults: defaults)
        WatchSessionImporter.apply(envelope(session(name: "Evening", exercises: [
            PerformedExercise(name: "Row", sets: [PerformedSet(weightKg: 70, reps: 10)])
        ])), in: context, now: now, defaults: defaults)

        let days = try days(in: context)
        XCTAssertEqual(days.count, 1)
        XCTAssertEqual(days[0].orderedExercises.map(\.name), ["Bench Press", "Row"])
        // The day keeps the name it was given first.
        XCTAssertEqual(days[0].name, "Upper A")
    }

    // MARK: - The watch edited the session after finishing it

    func testANewerRevisionReplacesAnImportNobodyHasTouched() throws {
        let context = makeContext()
        let defaults = isolatedDefaults()
        let id = UUID()

        WatchSessionImporter.apply(envelope(session(), id: id, revision: 2),
                                   in: context, now: now, defaults: defaults)
        let corrected = session(exercises: [
            PerformedExercise(name: "Bench Press", equipment: "barbell", sets: [
                PerformedSet(weightKg: 60, reps: 8, isWarmup: true, completedAt: started),
                PerformedSet(weightKg: 83.9146, reps: 6, rpe: 8, completedAt: now)
            ])
        ])
        let outcome = WatchSessionImporter.apply(envelope(corrected, id: id, revision: 3),
                                                 in: context, now: now, defaults: defaults)

        XCTAssertEqual(outcome, .stored)
        let day = try XCTUnwrap(try days(in: context).first)
        XCTAssertEqual(day.orderedExercises.count, 1, "the earlier import must be replaced, not added to")
        XCTAssertEqual(day.orderedExercises[0].orderedSets.map(\.reps), [8, 6])
        XCTAssertEqual(day.orderedExercises[0].orderIndex, 0,
                       "and the replacement is numbered as if the old rows had gone")
        XCTAssertEqual(day.totalSetCount, 2)
    }

    // MARK: - The phone edited the day after the watch finished

    /// The conflict rule, in code: `revision` wins, the phone reconciles,
    /// and **the watch never silently overwrites newer phone edits**. The
    /// watch's newer revision is refused, and what the lifter did on the
    /// phone stands.
    func testANewerRevisionDoesNotOverwriteAnEditMadeOnThePhone() throws {
        let context = makeContext()
        let defaults = isolatedDefaults()
        let id = UUID()
        WatchSessionImporter.apply(envelope(session(), id: id, revision: 2),
                                   in: context, now: now, defaults: defaults)

        // The lifter corrects the working set here, on the phone.
        let day = try XCTUnwrap(try days(in: context).first)
        let workingSet = try XCTUnwrap(day.orderedExercises[0].orderedSets.last)
        workingSet.reps = 4
        try context.save()

        let outcome = WatchSessionImporter.apply(
            envelope(session(exercises: [
                PerformedExercise(name: "Bench Press", equipment: "barbell", sets: [
                    PerformedSet(weightKg: 60, reps: 8, isWarmup: true, completedAt: started),
                    PerformedSet(weightKg: 100, reps: 12, rpe: 8, completedAt: now)
                ])
            ]), id: id, revision: 3),
            in: context, now: now, defaults: defaults)

        XCTAssertEqual(outcome, .conflict)
        let after = try XCTUnwrap(try days(in: context).first)
        XCTAssertEqual(after.orderedExercises[0].orderedSets.map(\.reps), [8, 4])
        XCTAssertEqual(after.orderedExercises[0].orderedSets.map(\.weightKg), [60, 83.9146])
    }

    /// And it is decided once: a fourth revision arriving after a conflict
    /// does not re-open it, and still does not touch the phone's rows.
    func testAConflictIsNotReconsideredOnEveryResend() throws {
        let context = makeContext()
        let defaults = isolatedDefaults()
        let id = UUID()
        WatchSessionImporter.apply(envelope(session(), id: id, revision: 2),
                                   in: context, now: now, defaults: defaults)
        let day = try XCTUnwrap(try days(in: context).first)
        day.orderedExercises[0].orderedSets.last?.reps = 4
        try context.save()

        _ = WatchSessionImporter.apply(envelope(session(), id: id, revision: 3),
                                       in: context, now: now, defaults: defaults)
        let again = WatchSessionImporter.apply(envelope(session(), id: id, revision: 3),
                                               in: context, now: now, defaults: defaults)

        XCTAssertEqual(again, .duplicate)
        XCTAssertEqual(try days(in: context).first?.orderedExercises.first?
            .orderedSets.map(\.reps), [8, 4])
    }

    /// A day the lifter deleted is not quietly rebuilt by a resend either.
    func testADeletedImportIsNotResurrectedByANewerRevision() throws {
        let context = makeContext()
        let defaults = isolatedDefaults()
        let id = UUID()
        WatchSessionImporter.apply(envelope(session(), id: id, revision: 2),
                                   in: context, now: now, defaults: defaults)
        for day in try days(in: context) { context.delete(day) }
        try context.save()

        let outcome = WatchSessionImporter.apply(envelope(session(), id: id, revision: 3),
                                                 in: context, now: now, defaults: defaults)

        XCTAssertEqual(outcome, .conflict)
        XCTAssertTrue(try days(in: context).isEmpty)
    }

    // MARK: - A day this phone already has

    /// A day is the unit of record, and it may already hold a workout that
    /// was logged here. The watch's session is appended to it.
    func testAWorkoutLoggedOnThePhoneIsNotReplaced() throws {
        let context = makeContext()
        let existing = WorkoutDay(date: started, name: "Leg day", focus: .bodybuilding)
        let squat = ExerciseEntry(exerciseRefID: "ex:1", name: "Squat", orderIndex: 0)
        squat.sets = [SetEntry(orderIndex: 0, weightKg: 100, reps: 5)]
        existing.exercises = [squat]
        context.insert(existing)
        try context.save()

        WatchSessionImporter.apply(envelope(session()), in: context, now: now,
                                   defaults: isolatedDefaults())

        let days = try days(in: context)
        XCTAssertEqual(days.count, 1)
        XCTAssertEqual(days[0].orderedExercises.map(\.name), ["Squat", "Bench Press"])
        XCTAssertEqual(days[0].name, "Leg day", "a day the lifter named keeps its name")
        XCTAssertEqual(days[0].focus, .bodybuilding, "and the focus they chose")
    }

    // MARK: - When the two clocks disagree about the day

    func testASessionFromEarlierTodayIsFiledUnderItsOwnDay() {
        let date = WatchSessionImporter.date(for: session(), now: now)
        XCTAssertEqual(date, started, "the exact moment, when the day agrees")
    }

    /// A queued session delivered days later still belongs to the day it was
    /// trained on.
    func testASessionQueuedForDaysKeepsItsOwnDay() throws {
        let context = makeContext()
        let threeDaysLater = try XCTUnwrap(
            Calendar.current.date(byAdding: .day, value: 3, to: now))

        WatchSessionImporter.apply(envelope(session()), in: context, now: threeDaysLater,
                                   defaults: isolatedDefaults())

        XCTAssertEqual(try days(in: context).first?.dayKey, DayKey.make(from: started))
    }

    /// A watch back from a flat battery believing it is 2016 is a clock, not
    /// a calendar. The session is stored — never dropped — under the day the
    /// phone is actually in, because a workout filed under the wrong year is
    /// one the lifter never finds again.
    func testASessionFromAnImpossibleDayIsFiledUnderThePhonesToday() throws {
        let context = makeContext()

        WatchSessionImporter.apply(envelope(session(performedOn: "2016-01-04")),
                                   in: context, now: now, defaults: isolatedDefaults())

        let day = try XCTUnwrap(try days(in: context).first)
        XCTAssertEqual(day.dayKey, DayKey.make(from: now))
        XCTAssertEqual(day.totalSetCount, 2)
    }

    func testASessionDatedInTheFutureIsFiledUnderThePhonesToday() throws {
        let context = makeContext()
        let nextWeek = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: 7, to: now))

        WatchSessionImporter.apply(envelope(session(performedOn: DayKey.make(from: nextWeek))),
                                   in: context, now: now, defaults: isolatedDefaults())

        XCTAssertEqual(try days(in: context).first?.dayKey, DayKey.make(from: now))
    }

    /// A day ahead is a time zone, not a broken clock: a watch that is over
    /// the date line from the phone is believed.
    func testADayAheadIsBelieved() throws {
        let context = makeContext()
        let tomorrow = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: 1, to: now))

        WatchSessionImporter.apply(envelope(session(performedOn: DayKey.make(from: tomorrow))),
                                   in: context, now: now, defaults: isolatedDefaults())

        XCTAssertEqual(try days(in: context).first?.dayKey, DayKey.make(from: tomorrow))
    }

    /// The two apps write the same key for the same day. They are different
    /// implementations — `WireDay` is `LiftSync`'s, `DayKey` is LiftKit's —
    /// so nothing but a test keeps them saying the same thing.
    func testTheWiresDayKeyAndThisAppsAgree() {
        XCTAssertEqual(WireDay.key(for: started), DayKey.make(from: started))
        XCTAssertEqual(WireDay.key(for: now), DayKey.make(from: now))
    }
}
