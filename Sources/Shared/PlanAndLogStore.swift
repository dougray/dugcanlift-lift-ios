import Foundation
import SwiftData
import LiftCore

/// Where the week card's two halves come from: **the accepted plan** for what
/// was asked, and **this phone's own days** for what came back.
///
/// Separate from `PlanAndLog` itself, which holds the rule and knows nothing
/// about SwiftData -- the split `LiftProgression` and `RoutineRemoval` already
/// follow, so the rule can be tested on values alone.
///
/// **The ask is the stored plan, not the logged sets.** A `ScheduledSession`
/// names the date and the `Routine` a coach booked on it, and that routine's
/// `RoutineExercise` / `RoutinePrescribedSet` rows are what was asked --
/// kilograms, as everything in this app is. `PlanSides` carries the two things
/// PLAN-FORMAT puts on top of them: which exercises are **each side**, and
/// which prescribed sets **name a side**.
///
/// It is deliberately not read off the log. Starting a booked session copies
/// its two-sided prescribed sets in as ordinary, editable sets, and
/// `PlanSides.logged` keeps a prescription beside a logged exercise *only when
/// that prescription says something about sides* -- so for an ordinary plan the
/// original ask is gone from the log the moment a set is edited. That is the
/// gap this card exists to close, and reading the ask from the log would close
/// it with the log's own numbers.
///
/// The cost, stated: a routine a lifter then edits changes what this card says
/// was asked, because the routine *is* the record and there is no second copy
/// of it. Deleting one is safe -- `RoutineRemoval` takes its `ScheduledSession`
/// rows with it, so a booking never outlives its routine. A booking left over
/// from a store written before that reaper still draws its day and its name,
/// with no lifts under it.
extension PlanAndLog {

    /// Every day a coach's accepted plans book. `compare` keeps the week it is
    /// looking at and drops the rest.
    ///
    /// One `Booking` per `ScheduledSession`; two booked on one date pool in
    /// `compare`. A session whose routine is gone keeps its own recorded name
    /// and books no lifts.
    static func bookings(sessions: [ScheduledSession], routines: [Routine],
                         sides: PlanSides) -> [Booking] {
        let byID = Dictionary(routines.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return inOrder(sessions).map { session in
            let routine = byID[session.routineID]
            return Booking(
                date: session.dayKey,
                name: session.routineName,
                coachName: session.coachName,
                exercises: (routine?.orderedExercises ?? []).map { asked($0, sides: sides) })
        }
    }

    /// Who sent the week, from the bookings themselves.
    ///
    /// The same order `bookings` puts them in, because `sentBy` prints two
    /// coaches in the order it first meets them and a `@Query` has no order of
    /// its own -- two names would otherwise swap places between launches.
    /// Only the date and the name are read, so the routine behind a booking is
    /// not fetched to answer this.
    ///
    /// **One divergence from web, stated.** Web meets its bookings in the
    /// order the plans were accepted, so a week two coaches booked reads in
    /// that order; this reads in booked-date order. Nothing here can
    /// reproduce web's: a `ScheduledSession` records no moment of its own, and
    /// `ImportedPlan` is not reachable from one. Date order is the order the
    /// rows under the line are drawn in, which is the next best thing and is
    /// stable. It shows at all only when two coaches book one week and the
    /// later-dated plan arrived first.
    static func sentBy(_ result: Result, sessions: [ScheduledSession],
                       meals: [Meal] = []) -> String {
        sentBy(result, bookings: inOrder(sessions).map {
            Booking(date: $0.dayKey, name: $0.routineName, coachName: $0.coachName,
                    exercises: [])
        }, meals: meals)
    }

    private static func inOrder(_ sessions: [ScheduledSession]) -> [ScheduledSession] {
        sessions.sorted {
            $0.dayKey == $1.dayKey ? $0.routineName < $1.routineName : $0.dayKey < $1.dayKey
        }
    }

    /// One prescribed exercise, as the plan stored it.
    static func asked(_ exercise: RoutineExercise, sides: PlanSides) -> Exercise {
        Exercise(name: exercise.name, equipment: exercise.equipment,
                 eachSide: sides.isEachSide(exercise),
                 sets: exercise.orderedSets.map { set in
                     SetValues(weightKg: set.targetWeightKg,
                               reps: set.targetReps,
                               rpe: set.targetRPE,
                               durationSec: set.targetDurationSec,
                               distanceMeters: set.targetDistanceMeters,
                               side: sides.side(of: set))
                 })
    }

    /// One day's log: its lifts in the order they were logged, **warmups
    /// dropped**.
    ///
    /// Warmups are excluded on both sides -- a plan never prescribes one, and
    /// counting them would make "Asked 4 sets · logged 6" out of a proper warm
    /// up. `SetEntry.isWarmup` is its own column here, so there are no flag
    /// bits to mask; the browser and a share link pack it into `flags` bit 0,
    /// which is where "masked, never compared" comes from.
    ///
    /// A zero weight or zero reps is the absence `SetEntry.display` already
    /// reads it as, so a set prescribing only a duration does not print a
    /// weight nobody entered.
    static func loggedDay(_ day: WorkoutDay) -> LoggedDay {
        LoggedDay(date: day.dayKey, name: day.name,
                  exercises: day.orderedExercises.map { entry in
                      Exercise(name: entry.name, equipment: entry.equipment ?? "",
                               sets: entry.orderedSets
                                   .filter { !$0.isWarmup }
                                   .map(logged))
                  })
    }

    static func logged(_ set: SetEntry) -> SetValues {
        SetValues(weightKg: set.weightKg > 0 ? set.weightKg : nil,
                  reps: set.reps > 0 ? set.reps : nil,
                  rpe: set.rpe,
                  durationSec: set.durationSec,
                  distanceMeters: set.distanceMeters,
                  side: set.side)
    }

    /// This phone's planned meals, a coach's and the lifter's own in one list,
    /// each marked with which it is.
    ///
    /// **Both kinds, deliberately.** Which meals belong on the card is part of
    /// the rule, so `bookedMeals` is where the lifter's own are dropped rather
    /// than whatever fetched the rows -- a filter in a view could not be tested,
    /// and this one decides whether somebody's own note-taking is held up to them
    /// as an expectation.
    ///
    /// `mealType.rawValue` rather than the column behind it: `PlannedMeal` keeps
    /// its raw slot private and coerces an unknown one to dinner, so a slot this
    /// build cannot read never reaches here from this app's store. See
    /// `PlanAndLog.Meal.slot`.
    static func meals(_ planned: [PlannedMeal], coach: PlanMeals) -> [Meal] {
        planned.map { meal in
            Meal(date: meal.dayKey, slot: meal.mealType.rawValue, name: meal.recipeName,
                 servings: meal.servings, fromCoach: coach.isFromCoach(meal),
                 coachName: coach.coachName(of: meal))
        }
    }

    /// Every date a coach's plan books, whatever week it is in -- what the
    /// arrows step between. Dates only: nothing is read out of a week the card
    /// is not looking at.
    static func bookedDates(_ sessions: [ScheduledSession]) -> [String] {
        sessions.map(\.dayKey)
    }

    /// The same, with the weeks a coach booked **food** in.
    ///
    /// Without them a week a coach sent food for would be reachable only by
    /// standing in it, and the arrows would skip over a card that exists. A meal
    /// the lifter placed books no week: the arrow would land on a card that is
    /// not there.
    static func bookedDates(sessions: [ScheduledSession], meals: [Meal]) -> [String] {
        bookedDates(sessions) + meals.filter(\.fromCoach).map(\.date)
    }

    /// The whole card for one week, from rows a view already holds.
    static func compare(anchor: String, today: String,
                        sessions: [ScheduledSession], routines: [Routine],
                        days: [WorkoutDay], meals: [Meal] = [], sides: PlanSides,
                        unit: WeightUnit, locale: Locale = .current) -> Result? {
        compare(
            bookings: bookings(sessions: sessions, routines: routines, sides: sides),
            logged: days.map(loggedDay), meals: meals,
            today: today, anchor: anchor, unit: unit, locale: locale)
    }
}
