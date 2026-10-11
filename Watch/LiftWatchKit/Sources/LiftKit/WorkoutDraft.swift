import Foundation

/// A workout the watch can create and edit with no phone in range.
///
/// The draft is a value type on purpose: the watch owns its copy, and the
/// phone reconciles by `revision` rather than by wall-clock time, which is not
/// trustworthy across two devices.
///
/// Identifiers are stable for the life of the draft. Reconciliation on the
/// phone matches on them, so regenerating one would duplicate a workout.
public struct WorkoutDraft: Identifiable, Codable, Equatable, Sendable {

    public private(set) var id: UUID
    public private(set) var name: String
    public private(set) var focus: TrainingFocus
    public private(set) var exercises: [DraftExercise]

    /// Starts at 1 and increases by one per accepted edit. Never decreases.
    public private(set) var revision: Int
    public private(set) var startedAt: Date
    public private(set) var updatedAt: Date
    public private(set) var finishedAt: Date?

    public init(
        id: UUID = UUID(),
        name: String,
        focus: TrainingFocus = .bodybuilding,
        exercises: [DraftExercise] = [],
        revision: Int = 1,
        now: Date = Date(),
        updatedAt: Date? = nil,
        finishedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.focus = focus
        self.exercises = exercises
        self.revision = max(1, revision)
        self.startedAt = now
        self.updatedAt = updatedAt ?? now
        self.finishedAt = finishedAt
    }

    public var isFinished: Bool { finishedAt != nil }

    // MARK: - Derived values

    /// Warm-up sets are deliberately excluded, matching the phone app.
    public var totalVolumeKg: Double {
        exercises.reduce(0) { $0 + $1.volumeKg }
    }

    public var totalSetCount: Int {
        exercises.reduce(0) { $0 + $1.sets.count }
    }

    public var completedSetCount: Int {
        exercises.reduce(0) { $0 + $1.sets.filter { $0.completedAt != nil }.count }
    }

    public func exercise(_ id: UUID) -> DraftExercise? {
        exercises.first { $0.id == id }
    }

    public func set(_ id: UUID) -> DraftSet? {
        for exercise in exercises {
            if let match = exercise.sets.first(where: { $0.id == id }) { return match }
        }
        return nil
    }

    /// "12 of 15 sets · 17100 lb"
    public func summary(unit: WeightUnit) -> String {
        let volume = Int(unit.fromKilograms(totalVolumeKg).rounded())
        return "\(completedSetCount) of \(totalSetCount) sets · \(volume) \(unit.abbreviation)"
    }

    // MARK: - Edits
    //
    // Every mutation that actually changes something goes through `commit`, so
    // there is exactly one place where the revision can advance. A rejected
    // edit leaves the revision alone — otherwise the phone would see a bump
    // with no corresponding change and re-sync for nothing.

    private mutating func commit(_ now: Date) {
        revision += 1
        updatedAt = now
    }

    public mutating func rename(_ newName: String, now: Date = Date()) {
        guard newName != name else { return }
        name = newName
        commit(now)
    }

    public mutating func setFocus(_ newFocus: TrainingFocus, now: Date = Date()) {
        guard newFocus != focus else { return }
        focus = newFocus
        commit(now)
    }

    @discardableResult
    public mutating func addExercise(
        refID: String,
        name: String,
        primaryMuscle: String? = nil,
        equipment: String? = nil,
        now: Date = Date()
    ) -> UUID {
        let exercise = DraftExercise(
            exerciseRefID: refID,
            name: name,
            orderIndex: exercises.count,
            primaryMuscle: primaryMuscle,
            equipment: equipment
        )
        exercises.append(exercise)
        commit(now)
        return exercise.id
    }

    /// Returns the new set's id, or `nil` if the exercise is unknown — an
    /// unknown target is a caller bug, not a workout change, so no revision.
    @discardableResult
    public mutating func appendSet(
        to exerciseID: UUID,
        weightKg: Double,
        reps: Int,
        rpe: Double? = nil,
        isWarmup: Bool = false,
        now: Date = Date()
    ) -> UUID? {
        guard let index = exercises.firstIndex(where: { $0.id == exerciseID }) else { return nil }
        let set = DraftSet(
            orderIndex: exercises[index].sets.count,
            weightKg: weightKg,
            reps: reps,
            rpe: rpe,
            isWarmup: isWarmup
        )
        exercises[index].sets.append(set)
        commit(now)
        return set.id
    }

    @discardableResult
    public mutating func completeSet(_ setID: UUID, at date: Date = Date()) -> Bool {
        mutateSet(setID, now: date) { $0.completedAt = date }
    }

    @discardableResult
    public mutating func updateSet(
        _ setID: UUID,
        weightKg: Double? = nil,
        reps: Int? = nil,
        rpe: Double?? = nil,
        now: Date = Date()
    ) -> Bool {
        mutateSet(setID, now: now) { set in
            if let weightKg { set.weightKg = weightKg }
            if let reps { set.reps = reps }
            if let rpe { set.rpe = rpe }
        }
    }

    @discardableResult
    public mutating func finish(at date: Date = Date()) -> Bool {
        guard finishedAt == nil else { return false }
        finishedAt = date
        commit(date)
        return true
    }

    private mutating func mutateSet(
        _ setID: UUID,
        now: Date,
        _ change: (inout DraftSet) -> Void
    ) -> Bool {
        for exerciseIndex in exercises.indices {
            guard let setIndex = exercises[exerciseIndex].sets
                .firstIndex(where: { $0.id == setID }) else { continue }
            let before = exercises[exerciseIndex].sets[setIndex]
            change(&exercises[exerciseIndex].sets[setIndex])
            if exercises[exerciseIndex].sets[setIndex] != before { commit(now) }
            return true
        }
        return false
    }
}

public struct DraftExercise: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    /// Reference-data id. `name`/`equipment` are snapshots so that history does
    /// not change when the exercise database is updated.
    public let exerciseRefID: String
    public var name: String
    public var primaryMuscle: String?
    public var equipment: String?
    public var orderIndex: Int
    public var sets: [DraftSet]

    public init(
        id: UUID = UUID(),
        exerciseRefID: String,
        name: String,
        orderIndex: Int,
        primaryMuscle: String? = nil,
        equipment: String? = nil,
        sets: [DraftSet] = []
    ) {
        self.id = id
        self.exerciseRefID = exerciseRefID
        self.name = name
        self.orderIndex = orderIndex
        self.primaryMuscle = primaryMuscle
        self.equipment = equipment
        self.sets = sets
    }

    /// "Deadlift (Barbell)" — equipment in parentheses, as on the phone.
    public var displayName: String {
        guard let equipment, !equipment.isEmpty else { return name }
        return "\(name) (\(equipment.capitalized))"
    }

    public var volumeKg: Double {
        sets.reduce(0) { $0 + $1.volumeKg }
    }

    public var nextSetNumber: Int { sets.count + 1 }
}

public struct DraftSet: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var orderIndex: Int
    public var weightKg: Double
    public var reps: Int
    /// 6–10 in half steps, shown inline on every set like the phone does.
    public var rpe: Double?
    public var isWarmup: Bool
    public var completedAt: Date?

    public init(
        id: UUID = UUID(),
        orderIndex: Int,
        weightKg: Double = 0,
        reps: Int = 0,
        rpe: Double? = nil,
        isWarmup: Bool = false,
        completedAt: Date? = nil
    ) {
        self.id = id
        self.orderIndex = orderIndex
        self.weightKg = weightKg
        self.reps = reps
        self.rpe = rpe
        self.isWarmup = isWarmup
        self.completedAt = completedAt
    }

    public var volumeKg: Double {
        isWarmup ? 0 : Double(reps) * weightKg
    }

    /// "325 x 5 @7.5" — weight, reps, then RPE, matching the phone app.
    public func display(unit: WeightUnit) -> String {
        let weight = unit.fromKilograms(weightKg)
        let rounded = (weight * 10).rounded() / 10
        let weightText = rounded == rounded.rounded()
            ? String(Int(rounded))
            : String(format: "%.1f", rounded)
        var text = "\(weightText) x \(reps)"
        if let rpe {
            let rpeText = rpe == rpe.rounded() ? String(Int(rpe)) : String(format: "%.1f", rpe)
            text += " @\(rpeText)"
        }
        return text
    }

    /// Epley. Only meaningful in the 1–10 rep range.
    public var estimatedOneRepMaxKg: Double? {
        guard reps > 0, weightKg > 0, !isWarmup else { return nil }
        return weightKg * (1 + Double(reps) / 30.0)
    }
}

public enum TrainingFocus: String, Codable, CaseIterable, Identifiable, Sendable {
    case bodybuilding, powerlifting, crossfit, conditioning

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .bodybuilding: return "Bodybuilding"
        case .powerlifting: return "Powerlifting"
        case .crossfit:     return "CrossFit"
        case .conditioning: return "Conditioning"
        }
    }
}
