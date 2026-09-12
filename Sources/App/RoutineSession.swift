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
    /// set that has something iOS can log (see `isLoggableToday`).
    @MainActor
    @discardableResult
    func startSession(on date: Date, in context: ModelContext) -> WorkoutDay {
        let day = WorkoutQueries.fetchOrCreate(date, in: context)

        // Guard against duplicate invocation: nothing marks a
        // ScheduledSession as consumed once started (TrainView's
        // "Coach scheduled: X" banner stays tappable), and a plain Button in
        // a List row can make the whole row a tap target — so the same
        // routine can plausibly be started twice for the same day. Skip any
        // exercise already landed on this day from this routine, identified
        // by the same "routine:<exercise id>" exerciseRefID convention used
        // below, rather than appending a second copy.
        let existingRefIDs = Set(day.exercises.map(\.exerciseRefID))

        for exercise in orderedExercises {
            let refID = "routine:\(exercise.id.uuidString)"
            guard !existingRefIDs.contains(refID) else { continue }
            let entry = ExerciseEntry(
                exerciseRefID: refID,
                name: exercise.name,
                orderIndex: day.exercises.count,
                equipment: exercise.equipment.isEmpty ? nil : exercise.equipment
            )
            entry.sets = exercise.orderedSets
                .filter { $0.isLoggableToday }
                .enumerated()
                .map { index, prescribed in
                    SetEntry(
                        orderIndex: index,
                        weightKg: prescribed.targetWeightKg ?? 0,
                        reps: prescribed.targetReps ?? 0,
                        rpe: prescribed.targetRPE
                    )
                }
            day.exercises.append(entry)
        }

        try? context.save()
        return day
    }
}
