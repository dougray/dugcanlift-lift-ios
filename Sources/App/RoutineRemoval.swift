import Foundation
import SwiftData
import LiftCore

/// Deleting a routine: what goes with it, what must not, and the sentence the
/// lifter is asked before any of it happens.
///
/// A value type with no view in it, the rule `PlanSides` and `RoadFoodRanking`
/// already follow here and `ClientRemoval` follows in Coach: a rule living in
/// a view's `@State` cannot be tested, and this one decides what somebody
/// loses. Coach's own `ScheduledSession.deleteRoutineAndSessions` is the
/// nearest relative — same problem, same answer.
///
/// **What goes.** The `Routine` and, by SwiftData's cascade rules, its
/// `RoutineExercise`s and through those every `RoutinePrescribedSet`. Plus the
/// three things that name a routine as a plain value, which no cascade
/// reaches:
///
/// 1. Every `ScheduledSession` a coach booked it on. Left behind, one of those
///    draws "Coach scheduled: Push" on its day forever and does nothing when
///    it is tapped — `ScheduledSessionsSection.start` fetches the routine and
///    returns when there is none.
/// 2. The `WatchPlanPin`, when it is this routine. The pin is one day's "run
///    this on the watch", and a pin at a routine that no longer exists is a
///    push that silently falls through to whatever is scheduled instead.
/// 3. This routine's entries in `PlanSides.eachSide` and `PlanSides.sides`,
///    which are keyed by `RoutineExercise.id` and `RoutinePrescribedSet.id` —
///    ids that stop existing with the rows.
///
/// **What stays, and this is the important half.** Every workout already
/// logged from it. `WorkoutDay`, `ExerciseEntry` and `SetEntry` copy the name
/// and the numbers at log time ("Snapshot reference data on write"), and an
/// entry's `exerciseRefID` is the plain string `"routine:<uuid>"` rather than
/// a relationship — so history is untouched by tidying a template away, which
/// is the whole point of snapshotting it. `PlanSides.logged` stays with it:
/// that map is deliberately "a copy, not a link back to the routine, so the
/// targets survive the routine being edited or deleted".
///
/// Deleting a routine also hands back its ready-made twin, with no work here:
/// `StarterSplits.isAlreadySaved` matches on the saved routines, so the split
/// reappears under "Ready-made" the moment the copy is gone.
enum RoutineRemoval {

    /// What a delete would take, counted before anything is touched.
    struct Summary: Equatable {
        /// `ScheduledSession`s a coach booked this routine on, across every day.
        var scheduledDays: Int = 0
        /// Whether this routine is the day's pinned watch plan.
        var isPinnedToWatch: Bool = false
    }

    static func summary(for routine: Routine, in context: ModelContext,
                        defaults: UserDefaults = .standard) -> Summary {
        Summary(scheduledDays: sessions(for: routine.id, in: context).count,
                isPinnedToWatch: WatchPlanPin.load(from: defaults)?.routineID == routine.id)
    }

    /// The question, in the app's own voice.
    ///
    /// What stays is always said, because that is the part nobody can check
    /// afterwards. A count of zero is left out entirely rather than said as
    /// "0 days" — Coach's confirmation makes the same distinction, and for the
    /// same reason: a clause about nothing is noise in a sentence somebody has
    /// to read before tapping Delete.
    static func warning(_ summary: Summary) -> String {
        var parts = ["Its exercises and target sets go with it. "
                     + "Workouts you have already logged from it stay."]
        switch summary.scheduledDays {
        case 0: break
        case 1: parts.append("One day your coach scheduled it for goes too.")
        case let count: parts.append("\(count) days your coach scheduled it for go too.")
        }
        if summary.isPinnedToWatch {
            parts.append("It is today's watch plan, so that is cleared too.")
        }
        return parts.joined(separator: " ")
    }

    /// Removes the routine and everything above. One `save()`: a failure rolls
    /// the whole thing back, so there is no half-deleted routine with its
    /// bookings already gone.
    @discardableResult
    static func remove(_ routine: Routine, in context: ModelContext,
                       defaults: UserDefaults = .standard) -> Bool {
        let exerciseIDs = Set(routine.orderedExercises.map(\.id))
        let setIDs = Set(routine.orderedExercises.flatMap { $0.orderedSets.map(\.id) })
        let routineID = routine.id

        for session in sessions(for: routineID, in: context) { context.delete(session) }
        context.delete(routine)
        do {
            try context.save()
        } catch {
            context.rollback()
            return false
        }

        // Only after the store has committed, so a rolled-back delete keeps
        // the lifter's side-cars — the ordering `ClientRemoval` uses for the
        // same reason.
        if WatchPlanPin.load(from: defaults)?.routineID == routineID {
            WatchPlanPin.clear(from: defaults)
        }
        sweepSides(exerciseIDs: exerciseIDs, setIDs: setIDs, in: defaults)
        return true
    }

    // MARK: - The rows no cascade reaches

    private static func sessions(for routineID: UUID, in context: ModelContext) -> [ScheduledSession] {
        let descriptor = FetchDescriptor<ScheduledSession>(
            predicate: #Predicate<ScheduledSession> { $0.routineID == routineID })
        return (try? context.fetch(descriptor)) ?? []
    }

    /// Drops this routine's prescription sides, and nothing else. `logged` is
    /// untouched: it is keyed by `ExerciseEntry.id` and belongs to a session
    /// that happened, not to the template it came from.
    private static func sweepSides(exerciseIDs: Set<UUID>, setIDs: Set<UUID>,
                                   in defaults: UserDefaults) {
        guard !exerciseIDs.isEmpty || !setIDs.isEmpty else { return }
        var sides = PlanSides.load(from: defaults)
        let before = sides
        sides.eachSide.subtract(exerciseIDs)
        for id in setIDs { sides.sides.removeValue(forKey: id) }
        guard sides != before else { return }
        sides.save(to: defaults)
    }
}
