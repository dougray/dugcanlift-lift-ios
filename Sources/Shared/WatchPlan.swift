import Foundation

// MARK: - Wire types
//
// Hand-mirrored from `dugcanlift-lift-watch/shared/contracts/workout-sync.schema.json`
// and its Swift port in that repo's `apple/LiftKit/Sources/LiftKit/WorkoutPlan.swift`
// — ported, not shared source, exactly as `SyncEnvelope` itself is. The field
// names below ARE the contract; `WatchPlanWireTests` pins every one of them,
// and the watch's `WorkoutPlanTests` pins the same spellings from the other
// side. Changing a name here without changing it there is a silent break.

/// The workout the watch should run, carried by a `PLAN_PUSHED` envelope.
///
/// Identity is the envelope's, not this payload's: `workoutId` is the plan's
/// id (the routine's) and `revision` is the plan's revision, so a re-push
/// reconciles under the rule the schema already states.
struct WorkoutPlan: Codable, Equatable, Sendable {

    enum Source: String, Codable, Sendable {
        case routine   = "ROUTINE"
        case coachPlan = "COACH_PLAN"
    }

    var name: String
    var source: Source
    /// Local calendar day, `yyyy-MM-dd` — `DayKey`'s own spelling. Absent
    /// when the plan is not tied to a date.
    var scheduledFor: String?
    var exercises: [PlanExercise]
}

struct PlanExercise: Codable, Equatable, Sendable {
    var name: String
    /// Omitted rather than sent as "": a lift's identity is name *and*
    /// equipment, and an empty string is not an equipment.
    var equipment: String?
    var note: String?
    var sets: [PrescribedSet]
    /// What was actually done the last time this exercise was trained. The
    /// watch has no history of its own, so if the phone does not send this,
    /// the Now screen has no "last:" line to show.
    var lastPerformed: LastPerformed?
}

/// One prescribed set. **Every field is optional**, keeping PLAN-FORMAT.md's
/// rule that a prescription is often partial: reps with no weight is "five
/// reps, you pick the weight". This is why `weightKg` is `Double?` and not
/// the plain `Double` that `SetEntry` (an actual, performed set) uses — a
/// blank prescription must never reach the watch as a zero.
struct PrescribedSet: Codable, Equatable, Sendable {
    /// KILOGRAMS, as everything stored in this app is. PLAN-FORMAT's set
    /// tuple is pounds; this is not that format, and the field name carries
    /// the unit so no future reader has to remember which contract they are
    /// holding.
    var weightKg: Double?
    var reps: Int?
    var rpe: Double?
    /// Rest *after* this set. Absent means the phone has no opinion and the
    /// watch uses its own default — it does not mean zero rest.
    var restSeconds: Int?
}

/// An actual set from the phone's history.
struct LastPerformed: Codable, Equatable, Sendable {
    var weightKg: Double?
    var reps: Int?
    var rpe: Double?
    /// `yyyy-MM-dd`, local.
    var performedOn: String?
}

/// Heart rate for one lifting session, arriving on `SESSION_FINISHED`. The
/// samples themselves are written to HealthKit by the watch, which is the
/// store for them; these two numbers are what can be shown without reading
/// Health back.
struct SessionHeartRate: Codable, Equatable, Sendable {
    var averageBpm: Double
    var maxBpm: Double
}
