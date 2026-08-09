import Foundation
import SwiftData

@Model
final class WorkoutSession {
    var id: UUID = UUID()
    var startedAt: Date = Date.now
    var endedAt: Date?
    var dayKey: String = ""
    var title: String = "Workout"
    var notes: String?

    /// Set once the session is written to HealthKit. Presence of a UUID makes
    /// sync idempotent — without it, every retry of a failed background sync
    /// creates a duplicate workout in the Health app.
    var healthKitUUID: UUID?

    @Relationship(deleteRule: .cascade, inverse: \ExerciseEntry.session)
    var exercises: [ExerciseEntry] = []

    init(startedAt: Date = .now, title: String = "Workout") {
        self.id = UUID()
        self.startedAt = startedAt
        self.dayKey = DayKey.make(from: startedAt)
        self.title = title
    }

    var isActive: Bool { endedAt == nil }

    var duration: TimeInterval {
        (endedAt ?? .now).timeIntervalSince(startedAt)
    }

    var orderedExercises: [ExerciseEntry] {
        exercises.sorted { $0.orderIndex < $1.orderIndex }
    }

    var totalVolumeKg: Double {
        exercises.reduce(0) { $0 + $1.volumeKg }
    }

    var completedSetCount: Int {
        exercises.reduce(0) { $0 + $1.sets.filter { $0.completedAt != nil }.count }
    }
}

@Model
final class ExerciseEntry {
    var id: UUID = UUID()

    /// Foreign key into the bundled reference database, namespaced by source
    /// (e.g. "wger:192"). Namespacing lets you add a second reference source
    /// later without an ID collision or a migration.
    var exerciseRefID: String = ""

    /// Denormalised snapshot. History must not mutate when you ship an updated
    /// reference database, and the widget can render without opening SQLite.
    var name: String = ""
    var primaryMuscle: String?
    var equipment: String?

    var orderIndex: Int = 0
    var session: WorkoutSession?

    @Relationship(deleteRule: .cascade, inverse: \SetEntry.exercise)
    var sets: [SetEntry] = []

    init(exerciseRefID: String, name: String, orderIndex: Int,
         primaryMuscle: String? = nil, equipment: String? = nil) {
        self.id = UUID()
        self.exerciseRefID = exerciseRefID
        self.name = name
        self.orderIndex = orderIndex
        self.primaryMuscle = primaryMuscle
        self.equipment = equipment
    }

    var orderedSets: [SetEntry] {
        sets.sorted { $0.orderIndex < $1.orderIndex }
    }

    var volumeKg: Double {
        sets.reduce(0) { $0 + $1.volumeKg }
    }

    var heaviestSet: SetEntry? {
        sets.filter { !$0.isWarmup }.max { $0.weightKg < $1.weightKg }
    }
}

@Model
final class SetEntry {
    var id: UUID = UUID()
    var orderIndex: Int = 0
    var reps: Int = 0

    /// Always kilograms. Pounds are a display concern only — storing whatever
    /// unit the user happened to be using is how you end up with a history
    /// that silently mixes both and totals that mean nothing.
    var weightKg: Double = 0

    var isWarmup: Bool = false
    var rpe: Double?
    var completedAt: Date?
    var exercise: ExerciseEntry?

    init(orderIndex: Int, reps: Int = 0, weightKg: Double = 0, isWarmup: Bool = false) {
        self.id = UUID()
        self.orderIndex = orderIndex
        self.reps = reps
        self.weightKg = weightKg
        self.isWarmup = isWarmup
    }

    /// Warm-up sets are deliberately excluded from volume.
    var volumeKg: Double {
        isWarmup ? 0 : Double(reps) * weightKg
    }

    /// Epley formula. Only meaningful in the 1–10 rep range.
    var estimatedOneRepMaxKg: Double? {
        guard reps > 0, weightKg > 0, !isWarmup else { return nil }
        return weightKg * (1 + Double(reps) / 30.0)
    }
}

enum WeightUnit: String, Codable, CaseIterable {
    case kilograms, pounds

    var abbreviation: String { self == .kilograms ? "kg" : "lb" }

    func fromKilograms(_ kg: Double) -> Double {
        self == .kilograms ? kg : kg * 2.2046226218
    }

    func toKilograms(_ value: Double) -> Double {
        self == .kilograms ? value : value / 2.2046226218
    }
}

@Model
final class BodyMeasurement {
    var id: UUID = UUID()
    var recordedAt: Date = Date.now
    var dayKey: String = ""
    var weightKg: Double?
    var bodyFatPercent: Double?
    var healthKitUUID: UUID?

    init(recordedAt: Date = .now, weightKg: Double? = nil, bodyFatPercent: Double? = nil) {
        self.id = UUID()
        self.recordedAt = recordedAt
        self.dayKey = DayKey.make(from: recordedAt)
        self.weightKg = weightKg
        self.bodyFatPercent = bodyFatPercent
    }
}
