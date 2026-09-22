import Foundation

/// What the watch is meant to lift today, as the phone pushed it.
///
/// This is the `plan` payload of `shared/contracts/workout-sync.schema.json`,
/// carried by a `PLAN_PUSHED` envelope. The Codable shape below is a contract
/// with `lift-ios`'s hand-mirrored copy in `Sources/Shared/WatchPlan.swift`
/// and with the schema — `WorkoutPlanTests` pins the JSON key spellings on
/// this side, `WatchPlanWireTests` pins them on the phone's.
///
/// The plan is *not* the workout. Training against it builds an ordinary
/// `WorkoutDraft`, exactly as free entry does, so everything downstream of a
/// logged set — revisions, the outbox, `SESSION_FINISHED` — is unchanged.
///
/// Identity lives on the envelope, not in here: the envelope's `workoutId` is
/// the plan's id and its `revision` is the plan's revision, so the existing
/// "newer revision wins, older is ignored" rule covers a re-push with no new
/// machinery.
public struct WorkoutPlan: Codable, Equatable, Sendable {

    /// Where the plan came from, so the watch can say so on screen.
    public enum Source: String, Codable, Sendable {
        case routine   = "ROUTINE"
        case coachPlan = "COACH_PLAN"

        public var displayName: String {
            switch self {
            case .routine:   return "Routine"
            case .coachPlan: return "From your coach"
            }
        }
    }

    public var name: String
    public var source: Source
    /// Local calendar day, `yyyy-MM-dd`, with no time component — the shape
    /// PLAN-FORMAT.md uses. Absent when the plan is not tied to a date.
    public var scheduledFor: String?
    public var exercises: [PlanExercise]

    public init(name: String, source: Source, scheduledFor: String? = nil,
                exercises: [PlanExercise]) {
        self.name = name
        self.source = source
        self.scheduledFor = scheduledFor
        self.exercises = exercises
    }

    public var totalSetCount: Int { exercises.reduce(0) { $0 + $1.sets.count } }
}

public struct PlanExercise: Codable, Equatable, Sendable {
    public var name: String
    /// Omitted rather than empty when there is none: a lift's identity is
    /// name *and* equipment, and "" is not an equipment.
    public var equipment: String?
    public var note: String?
    public var sets: [PrescribedSet]
    /// What was actually done the last time this exercise was trained. The
    /// phone owns all history, so this is the only way the watch can show
    /// "last: 185x5 @8" — it never computes it.
    public var lastPerformed: LastPerformed?

    public init(name: String, equipment: String? = nil, note: String? = nil,
                sets: [PrescribedSet], lastPerformed: LastPerformed? = nil) {
        self.name = name
        self.equipment = equipment
        self.note = note
        self.sets = sets
        self.lastPerformed = lastPerformed
    }

    /// "Deadlift (Barbell)" — the same convention `DraftExercise` uses.
    public var displayName: String {
        guard let equipment, !equipment.isEmpty else { return name }
        return "\(name) (\(equipment.capitalized))"
    }
}

/// One prescribed set. **Every field is optional**, keeping PLAN-FORMAT.md's
/// rule that a prescription is often partial: reps with no weight is "five
/// reps, you pick the weight". Absent is absent — nothing here may be
/// rendered or stored as a zero, which is why `weightKg` is `Double?` rather
/// than a `Double` defaulting to 0 as `DraftSet.weightKg` (an actual,
/// performed set) can afford to be.
public struct PrescribedSet: Codable, Equatable, Sendable {
    /// KILOGRAMS. PLAN-FORMAT's set tuple is pounds; this contract is not
    /// that format, and both apps store kilograms, so the field name carries
    /// the unit rather than leaving it to a convention that can be forgotten.
    public var weightKg: Double?
    public var reps: Int?
    public var rpe: Double?
    /// How long to rest *after* this set. Absent means the sender has no
    /// opinion and the watch uses its own default — never zero rest.
    public var restSeconds: Int?

    public init(weightKg: Double? = nil, reps: Int? = nil,
                rpe: Double? = nil, restSeconds: Int? = nil) {
        self.weightKg = weightKg
        self.reps = reps
        self.rpe = rpe
        self.restSeconds = restSeconds
    }

    public var isEmpty: Bool {
        weightKg == nil && reps == nil && rpe == nil
    }
}

/// An actual set, already performed, from the phone's history.
public struct LastPerformed: Codable, Equatable, Sendable {
    /// KILOGRAMS, as in `PrescribedSet`.
    public var weightKg: Double?
    public var reps: Int?
    public var rpe: Double?
    /// Local calendar day, `yyyy-MM-dd`.
    public var performedOn: String?

    public init(weightKg: Double? = nil, reps: Int? = nil,
                rpe: Double? = nil, performedOn: String? = nil) {
        self.weightKg = weightKg
        self.reps = reps
        self.rpe = rpe
        self.performedOn = performedOn
    }
}

/// Heart rate for one lifting session, travelling home on `SESSION_FINISHED`.
/// The samples themselves go to HealthKit, which is the store for them; these
/// two numbers are what the phone can show without reading Health.
public struct SessionHeartRate: Codable, Equatable, Sendable {
    public var averageBpm: Double
    public var maxBpm: Double

    public init(averageBpm: Double, maxBpm: Double) {
        self.averageBpm = averageBpm
        self.maxBpm = maxBpm
    }
}

// MARK: - Display
//
// Formatting lives here, beside the rules it formats, rather than in a view:
// "blank must never render as zero" is the whole point of these types, and a
// rule in a view's body cannot be tested.

extension PrescribedSet {

    /// The weight alone — "185" — or `nil` when none is prescribed. Rounded
    /// the way a plate-loaded bar actually goes: whole numbers stay whole.
    public func weightText(unit: WeightUnit) -> String? {
        guard let weightKg else { return nil }
        return PlanFormat.weight(weightKg, unit: unit)
    }

    /// The big line on the Now screen: "185 x 5", "5 reps", "185 lb", or
    /// "—" when this set prescribes nothing at all. Never "0 x 5".
    public func headline(unit: WeightUnit) -> String {
        switch (weightText(unit: unit), reps) {
        case let (weight?, reps?): return "\(weight) x \(reps)"
        case let (weight?, nil):   return "\(weight) \(unit.abbreviation)"
        case let (nil, reps?):     return "\(reps) reps"
        case (nil, nil):           return "—"
        }
    }

    /// Everything the set prescribes, RPE included: "185 x 5 @8".
    public func summary(unit: WeightUnit) -> String {
        var text = headline(unit: unit)
        if let rpe { text += " @\(PlanFormat.rpe(rpe))" }
        return text
    }
}

extension LastPerformed {
    /// "185x5 @8" — the reference line under the prescription. `nil` when the
    /// record holds no numbers worth showing, so the caller shows nothing at
    /// all rather than a dash pretending to be history.
    public func summary(unit: WeightUnit) -> String? {
        var text = ""
        if let weightKg, let reps {
            text = "\(PlanFormat.weight(weightKg, unit: unit))x\(reps)"
        } else if let weightKg {
            text = "\(PlanFormat.weight(weightKg, unit: unit)) \(unit.abbreviation)"
        } else if let reps {
            text = "\(reps) reps"
        } else {
            return nil
        }
        if let rpe { text += " @\(PlanFormat.rpe(rpe))" }
        return text
    }
}

public enum PlanFormat {
    /// Trailing ".0" is noise on a wrist; a real half-kilo is not.
    public static func weight(_ kilograms: Double, unit: WeightUnit) -> String {
        let value = unit.fromKilograms(kilograms)
        let rounded = (value * 10).rounded() / 10
        return rounded == rounded.rounded()
            ? String(Int(rounded))
            : String(format: "%.1f", rounded)
    }

    public static func rpe(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }
}
