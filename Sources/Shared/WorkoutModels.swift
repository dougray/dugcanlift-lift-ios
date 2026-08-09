import Foundation
import SwiftData

enum TrainingFocus: String, Codable, CaseIterable, Identifiable {
    case bodybuilding, powerlifting, crossfit, conditioning

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .bodybuilding: "Bodybuilding"
        case .powerlifting: "Powerlifting"
        case .crossfit:     "CrossFit"
        case .conditioning: "Conditioning"
        }
    }
}

/// A day's training log.
///
/// The day is the unit of record, not a timed session — any date can be opened
/// and logged against after the fact, which is how the Android app works.
///
/// A *live session* is an optional overlay: when `liveStartedAt` is set and
/// `liveEndedAt` is not, the user is training right now, which enables rest
/// timers and Live Activities. Nothing requires it, and a day logged
/// retroactively is equally valid.
@Model
final class WorkoutDay {
    var id: UUID = UUID()

    /// One record per calendar day.
    var dayKey: String = ""
    var date: Date = Date.now

    var name: String = ""
    private var focusRaw: String = TrainingFocus.bodybuilding.rawValue

    var focus: TrainingFocus {
        get { TrainingFocus(rawValue: focusRaw) ?? .bodybuilding }
        set { focusRaw = newValue.rawValue }
    }

    // Both nil for a retroactively logged day.
    var liveStartedAt: Date?
    var liveEndedAt: Date?

    var healthKitUUID: UUID?

    @Relationship(deleteRule: .cascade, inverse: \ExerciseEntry.day)
    var exercises: [ExerciseEntry] = []

    init(date: Date = .now, name: String = "", focus: TrainingFocus = .bodybuilding) {
        self.id = UUID()
        self.date = date
        self.dayKey = DayKey.make(from: date)
        self.name = name
        self.focusRaw = focus.rawValue
    }

    var isLive: Bool { liveStartedAt != nil && liveEndedAt == nil }

    var liveDuration: TimeInterval? {
        guard let start = liveStartedAt else { return nil }
        return (liveEndedAt ?? .now).timeIntervalSince(start)
    }

    var orderedExercises: [ExerciseEntry] {
        exercises.sorted { $0.orderIndex < $1.orderIndex }
    }

    var totalVolumeKg: Double {
        exercises.reduce(0) { $0 + $1.volumeKg }
    }

    var totalSetCount: Int {
        exercises.reduce(0) { $0 + $1.sets.count }
    }

    var hasContent: Bool { !exercises.isEmpty || !name.isEmpty }

    /// "15 sets · 17100 lb volume"
    func summary(unit: WeightUnit) -> String {
        let volume = Int(unit.fromKilograms(totalVolumeKg))
        return "\(totalSetCount) sets · \(volume) \(unit.abbreviation) volume"
    }
}

@Model
final class ExerciseEntry {
    var id: UUID = UUID()

    var exerciseRefID: String = ""
    // Snapshot fields — history must not change when reference data updates.
    var name: String = ""
    var primaryMuscle: String?
    var equipment: String?

    var orderIndex: Int = 0
    var day: WorkoutDay?

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

    /// "Deadlift (Barbell)" — equipment in parentheses, as on Android.
    var displayName: String {
        guard let equipment, !equipment.isEmpty else { return name }
        return "\(name) (\(equipment.capitalized))"
    }

    var orderedSets: [SetEntry] {
        sets.sorted { $0.orderIndex < $1.orderIndex }
    }

    var volumeKg: Double {
        sets.reduce(0) { $0 + $1.volumeKg }
    }
}

@Model
final class SetEntry {
    var id: UUID = UUID()
    var orderIndex: Int = 0

    /// Canonical kilograms regardless of what the user sees. Mixed-unit
    /// history is unrecoverable once it happens.
    var weightKg: Double = 0
    var reps: Int = 0

    /// Rate of perceived exertion, 6–10 in half steps. First-class here
    /// because the Android app shows it inline on every set.
    var rpe: Double?

    var isWarmup: Bool = false
    var completedAt: Date?
    var exercise: ExerciseEntry?

    init(orderIndex: Int, weightKg: Double = 0, reps: Int = 0,
         rpe: Double? = nil, isWarmup: Bool = false) {
        self.id = UUID()
        self.orderIndex = orderIndex
        self.weightKg = weightKg
        self.reps = reps
        self.rpe = rpe
        self.isWarmup = isWarmup
    }

    var volumeKg: Double {
        isWarmup ? 0 : Double(reps) * weightKg
    }

    /// "325 x 5 @7.5" — weight first, then reps, then RPE.
    func display(unit: WeightUnit) -> String {
        let weight = unit.fromKilograms(weightKg)
        let weightText = weight == weight.rounded()
            ? String(Int(weight))
            : String(format: "%.1f", weight)
        var text = "\(weightText) x \(reps)"
        if let rpe {
            let rpeText = rpe == rpe.rounded() ? String(Int(rpe)) : String(format: "%.1f", rpe)
            text += " @\(rpeText)"
        }
        return text
    }

    /// Epley. Only meaningful in the 1–10 rep range.
    var estimatedOneRepMaxKg: Double? {
        guard reps > 0, weightKg > 0, !isWarmup else { return nil }
        return weightKg * (1 + Double(reps) / 30.0)
    }
}

enum WeightUnit: String, Codable, CaseIterable {
    case pounds, kilograms

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

// MARK: - Queries

enum WorkoutQueries {
    static func day(_ dayKey: String) -> FetchDescriptor<WorkoutDay> {
        var descriptor = FetchDescriptor<WorkoutDay>(
            predicate: #Predicate { $0.dayKey == dayKey }
        )
        descriptor.fetchLimit = 1
        return descriptor
    }

    static func recent(limit: Int = 30) -> FetchDescriptor<WorkoutDay> {
        var descriptor = FetchDescriptor<WorkoutDay>(
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return descriptor
    }

    /// Fetches the day record, creating it if this is the first entry for it.
    @MainActor
    static func fetchOrCreate(_ date: Date, in context: ModelContext) -> WorkoutDay {
        let key = DayKey.make(from: date)
        if let existing = try? context.fetch(day(key)).first {
            return existing
        }
        let created = WorkoutDay(date: date)
        context.insert(created)
        return created
    }
}
