import Foundation
import SwiftData

/// A saved, reusable workout template — the iOS counterpart to Android's
/// `Routine`/`RoutineExercise` (see `LIFT/android/.../data/Routines.kt`).
///
/// A routine's sets are *targets*, not history. Starting a routine creates a
/// real `WorkoutDay`/`ExerciseEntry`/`SetEntry` prefilled from those targets,
/// exactly like logging any other day — the routine itself is never mutated
/// by training against it.
@Model
final class Routine {
    var id: UUID = UUID()
    var name: String = ""
    var folder: String = ""
    var createdAt: Date = Date.now

    @Relationship(deleteRule: .cascade, inverse: \RoutineExercise.routine)
    var exercises: [RoutineExercise]? = []

    init(name: String, folder: String = "", createdAt: Date = .now) {
        self.id = UUID()
        self.name = name
        self.folder = folder
        self.createdAt = createdAt
        self.exercises = []
    }

    var orderedExercises: [RoutineExercise] {
        (exercises ?? []).sorted { $0.orderIndex < $1.orderIndex }
    }
}

@Model
final class RoutineExercise {
    var id: UUID = UUID()
    var name: String = ""
    var equipment: String = ""
    var orderIndex: Int = 0
    var note: String?
    var routine: Routine?

    @Relationship(deleteRule: .cascade, inverse: \RoutinePrescribedSet.exercise)
    var prescribedSets: [RoutinePrescribedSet]? = []

    init(name: String, equipment: String = "", orderIndex: Int, note: String? = nil) {
        self.id = UUID()
        self.name = name
        self.equipment = equipment
        self.orderIndex = orderIndex
        self.note = note
        self.prescribedSets = []
    }

    var orderedSets: [RoutinePrescribedSet] {
        (prescribedSets ?? []).sorted { $0.orderIndex < $1.orderIndex }
    }

    /// "Deadlift (Barbell)" — same convention as `ExerciseEntry.displayName`.
    var displayName: String {
        guard !equipment.isEmpty else { return name }
        return "\(name) (\(equipment.capitalized))"
    }
}

@Model
final class RoutinePrescribedSet {
    var id: UUID = UUID()
    var orderIndex: Int = 0

    // All five optional, matching PLAN-FORMAT's
    // [weightLb, reps, rpe, durationSec, distanceMeters] tuple — a
    // prescription is often partial. Weight is converted to kilograms at
    // decode time (PlanImporter), so this is already canonical.
    var targetWeightKg: Double?
    var targetReps: Int?
    var targetRPE: Double?
    var targetDurationSec: Int?
    var targetDistanceMeters: Double?

    var exercise: RoutineExercise?

    init(orderIndex: Int,
         targetWeightKg: Double? = nil,
         targetReps: Int? = nil,
         targetRPE: Double? = nil,
         targetDurationSec: Int? = nil,
         targetDistanceMeters: Double? = nil) {
        self.id = UUID()
        self.orderIndex = orderIndex
        self.targetWeightKg = targetWeightKg
        self.targetReps = targetReps
        self.targetRPE = targetRPE
        self.targetDurationSec = targetDurationSec
        self.targetDistanceMeters = targetDistanceMeters
    }

    /// A set with no weight and no reps has nothing iOS can log today — see
    /// the "Out of scope" note in this feature's plan. Duration/distance are
    /// still stored above so nothing is lost if iOS's SetEntry gains those
    /// fields later.
    var isLoggableToday: Bool { targetWeightKg != nil || targetReps != nil }
}

extension Routine {
    /// Starts this routine on `date`: fetches or creates that day, appends one
    /// `ExerciseEntry` per routine exercise, and one `SetEntry` per prescribed
    /// set that has something iOS can log (see `isLoggableToday`).
    @MainActor
    @discardableResult
    func startSession(on date: Date, in context: ModelContext) -> WorkoutDay {
        let day = WorkoutQueries.fetchOrCreate(date, in: context)

        for exercise in orderedExercises {
            let entry = ExerciseEntry(
                exerciseRefID: "routine:\(exercise.id.uuidString)",
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
