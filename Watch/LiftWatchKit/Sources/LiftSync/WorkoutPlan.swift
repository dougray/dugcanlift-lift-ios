import Foundation

/// What the watch is meant to lift today, as the phone pushed it.
///
/// This is the `plan` payload of `Watch/contracts/workout-sync.schema.json`,
/// carried by a `PLAN_PUSHED` envelope. The phone builds it
/// (`WatchPlanBuilder`) and the watch runs it, and both compile this one
/// definition, so the two cannot disagree about a key. `WatchPlanWireTests`
/// pins the JSON spellings and `SchemaConformanceTests` checks them against
/// the schema file itself.
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
    public enum Source: String, Codable, CaseIterable, Sendable {
        case routine   = "ROUTINE"
        case coachPlan = "COACH_PLAN"
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
