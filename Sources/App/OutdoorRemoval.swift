import Foundation
import SwiftData
import LiftCore

/// Deleting a recorded run, walk or hike: what goes with it, what must not,
/// and the sentence somebody is asked before any of it happens.
///
/// A value type with no view in it, the rule `RoutineRemoval` and `PlanSides`
/// already follow here and `ClientRemoval` follows in Coach: a rule living in
/// a view's `@State` cannot be tested, and this one decides what somebody
/// loses.
///
/// **What goes.** The `OutdoorActivity` row, and with it the route — every
/// `RoutePoint` is encoded into `routePointsData` on the row itself rather
/// than stored as its own model, so the line on the map goes when the row
/// does, with nothing to sweep. Nothing else in the store names an activity:
/// there is no relationship to it and no id of one held as a plain value, so
/// unlike a `Routine` this delete leaves no orphan behind.
///
/// **What is worked out again, rather than deleted.** The personal bests and
/// the Last route card are `OutdoorRecords` reading the live query, and the
/// `o` / `ob` / `lr` a coach receives are `CoachShare` reading it at the
/// moment a link is made. None of them is a stored copy, so none of them
/// needs sweeping — the farthest run simply becomes whatever is now farthest,
/// and the coach's copy of the day catches up at the next send, because a
/// share link replaces the days it covers whole.
///
/// **What stays, and this is the half that matters: the workout in Apple
/// Health.** When LIFT has exported this activity (`healthKitUUID` is set) it
/// wrote an `HKWorkout` with its route into the person's Health store.
/// Deleting here does not touch it, deliberately:
///
/// 1. Health is not LIFT's data. Other apps and the Fitness rings have read
///    that workout by now, and a delete there is silent and has no undo.
/// 2. Nothing in this app has ever deleted from Health — `HealthKitManager`
///    only writes and reads — so doing it here would be a new and invisible
///    power for a button that reads as tidying up a list.
/// 3. It can fail for reasons nobody can see: deleting a sample needs share
///    authorization, which the person can revoke in Settings at any time
///    while LIFT goes on running.
///
/// The confirmation says so in words, so that "delete" never quietly means
/// less — or more — than it appears to. Deleting it in Health is one tap
/// there and nobody can do it by accident from here.
enum OutdoorRemoval {

    /// What a delete would take, counted before anything is touched.
    struct Summary: Equatable {
        /// This activity is in Apple Health, so the confirmation must say that
        /// the workout there stays.
        var isInHealth: Bool = false
        /// This activity currently holds at least one of its type's bests, so
        /// a figure on the Train screen changes when it goes.
        var holdsABest: Bool = false
        /// "Run", "Walk" or "Hike" — the word the sentence uses.
        var typeName: String = OutdoorActivityType.run.displayName
    }

    static func summary(for activity: OutdoorActivity, in context: ModelContext) -> Summary {
        let all = (try? context.fetch(FetchDescriptor<OutdoorActivity>())) ?? []
        return Summary(isInHealth: activity.healthKitUUID != nil,
                       holdsABest: holdsABest(activity, among: all),
                       typeName: activity.activityType.displayName)
    }

    /// The question, in the app's own voice.
    ///
    /// What stays is always said when there is something that stays, because
    /// that is the part nobody can check afterwards. A clause about nothing is
    /// left out entirely rather than said — no "it is in no bests", no "it was
    /// never saved to Health" — the distinction `RoutineRemoval`'s own
    /// confirmation makes, and Coach's.
    static func warning(_ summary: Summary) -> String {
        var parts = ["Its route goes with it."]
        if summary.holdsABest {
            parts.append("It holds one of your \(summary.typeName.lowercased()) bests, "
                         + "so that figure is worked out again without it.")
        }
        if summary.isInHealth {
            parts.append("The workout LIFT saved to Apple Health stays there. "
                         + "Delete it in the Health app if you want it gone.")
        }
        return parts.joined(separator: " ")
    }

    /// Removes the activity. One `save()`, so a failure rolls the whole thing
    /// back and there is no half-deleted run.
    ///
    /// Nothing here talks to HealthKit. See the note above: that is the point,
    /// not an omission.
    @discardableResult
    static func remove(_ activity: OutdoorActivity, in context: ModelContext) -> Bool {
        context.delete(activity)
        do {
            try context.save()
        } catch {
            context.rollback()
            return false
        }
        return true
    }

    // MARK: - Bests

    /// Whether this activity is the one behind any of its type's bests.
    ///
    /// Asked of `OutdoorRecords` rather than worked out again here, so the
    /// sentence can never claim a best this activity does not hold: the
    /// farthest, the longest and the fastest pace are compared against the
    /// same figures the Train screen draws, including its rule that a pace
    /// under `minimumPaceDistanceMeters` is GPS noise and no best at all.
    private static func holdsABest(_ activity: OutdoorActivity,
                                   among all: [OutdoorActivity]) -> Bool {
        guard activity.endedAt != nil,
              let bests = OutdoorRecords.bests(in: all).first(where: { $0.type == activity.activityType })
        else { return false }

        if let distance = bests.longestDistanceMeters, activity.distanceMeters == distance { return true }
        if let duration = bests.longestDuration, activity.duration == duration { return true }
        if let pace = bests.fastestPaceSecondsPerMeter,
           activity.distanceMeters >= OutdoorRecords.minimumPaceDistanceMeters,
           activity.averagePaceSecondsPerMeter == pace { return true }
        return false
    }
}
