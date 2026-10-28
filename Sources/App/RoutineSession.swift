import Foundation
import SwiftData
import LiftCore

/// `Routine.startSession(on:in:)` stays in lift-ios rather than moving into
/// the LiftCore package: it depends on `WorkoutQueries`, `WorkoutDay`,
/// `ExerciseEntry` and `SetEntry`, all of which live in
/// `Sources/Shared/WorkoutModels.swift` and must not move — dragging LIFT's
/// workout store into a shared package would couple a second app to LIFT's
/// schema forever.
extension Routine {
    /// Starts this routine on `date`: fetches or creates that day, appends one
    /// `ExerciseEntry` per routine exercise, and one `SetEntry` per prescribed
    /// set that prescribes anything at all — weight, reps, time or distance.
    @MainActor
    @discardableResult
    func startSession(on date: Date, in context: ModelContext,
                      defaults: UserDefaults = .standard) -> WorkoutDay {
        let day = WorkoutQueries.fetchOrCreate(date, in: context)
        var planSides = PlanSides.load(from: defaults)
        var loggedChanged = false
        // Supersets, drop sets and rest-pause go with the session as a copy
        // keyed by the logged rows, so the live session can train them.
        var setTypes = RoutineSetTypes.load(from: defaults)
        var setTypesChanged = false

        // Guard against duplicate invocation: nothing marks a
        // ScheduledSession as consumed once started (TrainView's
        // "Coach scheduled: X" banner stays tappable), and a plain Button in
        // a List row can make the whole row a tap target — so the same
        // routine can plausibly be started twice for the same day. Skip any
        // exercise already landed on this day from this routine, identified
        // by the same "routine:<exercise id>" exerciseRefID convention used
        // below, rather than appending a second copy.
        let existingRefIDs = Set(day.exercises.map(\.exerciseRefID))

        // A blank day takes the routine's name, as Android and the browser do.
        // A day already named — by the person, or by a routine started first —
        // keeps its name.
        if day.name.trimmingCharacters(in: .whitespaces).isEmpty {
            day.name = name
        }

        // This routine's groups as the wire numbers them, moved past any group
        // already on the day, so a second routine started beside the first
        // never joins its superset to the other's by being next to it.
        let exercises = orderedExercises
        let groups = ExerciseGrouping.runs(setTypes.storedGroups(exercises))
        let groupOffset = setTypes.nextLoggedGroupOffset(day.exercises)

        for (exerciseIndex, exercise) in exercises.enumerated() {
            let refID = "routine:\(exercise.id.uuidString)"
            guard !existingRefIDs.contains(refID) else { continue }
            let entry = ExerciseEntry(
                exerciseRefID: refID,
                name: exercise.name,
                orderIndex: day.exercises.count,
                equipment: exercise.equipment.isEmpty ? nil : exercise.equipment
            )
            // `isLoggableToday` predates SetEntry's time and distance (schema
            // V6) and dropped every timed set, so a mobility or running routine
            // started with its exercises and no sets at all. Time and distance
            // now land on the set like weight and reps do.
            // A coach's prescription with sides in it is kept with the logged
            // exercise, so the header can count against it ("L 0/3 · R 0/3")
            // and Add set can offer the side and the numbers of the next set it
            // asks for. Its sided sets are logged one at a time, as they are
            // done, rather than pre-filled: a pre-filled left set is a claim
            // nobody made yet. Two-sided sets of an exercise that is not each
            // side are copied in as they always were.
            let kinds = setTypes.kinds(of: exercise)
            var prescription = planSides.prescription(for: exercise)
            if var sided = prescription {
                // A sided set is logged by Add set, so its kind rides with
                // the prescription it is logged from.
                for index in sided.sets.indices where index < kinds.count {
                    sided.sets[index].kind = kinds[index]
                }
                prescription = sided
                planSides.logged[entry.id] = sided
                loggedChanged = true
            }
            if let group = groups[exerciseIndex] {
                setTypes.loggedGroups[entry.id] = groupOffset + group
                setTypesChanged = true
            }
            let copied = zip(exercise.orderedSets, kinds)
                .filter { set, _ in
                    guard let prescription else { return true }
                    return !prescription.eachSide && planSides.side(of: set) == nil
                }
                .filter { set, _ in
                    set.targetWeightKg != nil || set.targetReps != nil
                        || set.targetDurationSec != nil || set.targetDistanceMeters != nil
                }
            entry.sets = copied.enumerated().map { index, pair in
                let (prescribed, kind) = pair
                let set = SetEntry(
                    orderIndex: index,
                    weightKg: prescribed.targetWeightKg ?? 0,
                    reps: prescribed.targetReps ?? 0,
                    rpe: prescribed.targetRPE,
                    durationSec: prescribed.targetDurationSec,
                    distanceMeters: prescribed.targetDistanceMeters
                )
                if let kind {
                    setTypes.loggedKinds[set.id] = kind
                    setTypesChanged = true
                }
                return set
            }
            day.exercises.append(entry)
        }

        try? context.save()
        if loggedChanged { planSides.save(to: defaults) }
        if setTypesChanged { setTypes.save(to: defaults) }
        return day
    }
}
