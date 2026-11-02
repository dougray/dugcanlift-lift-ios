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

    /// Sets to actually perform, which is not the same as prescribed rows:
    /// an each-side exercise's "3 x 8" is six sets, three a side.
    public var totalSetCount: Int { exercises.reduce(0) { $0 + $1.plannedSets.count } }
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
    /// **Every prescribed set is done on both sides** (PLAN-FORMAT.md
    /// "Sides", `b: 1`): "3 x 8 each side" stays three prescribed rows and
    /// is six sets, three a side. The coach's own flag, carried through the
    /// phone's `PlanSides` — the watch never guesses it from a name.
    ///
    /// `false` is **omitted from the wire**, never written as `false`, so a
    /// plan with no sides is byte for byte what the build before this wrote
    /// and its content hash — and so its revision — does not move.
    public var eachSide: Bool
    /// **The superset or circuit this exercise is in** (PLAN-FORMAT.md "Set
    /// types", `g`): adjacent exercises with the same number are done round
    /// by round -- one set of each, then the rest. Two make a superset,
    /// three or more a circuit. **Adjacency makes the group, not the
    /// number**, so a group of one is no group; `PlanGrouping.runs` is the
    /// one reader of it.
    ///
    /// Only a positive integer: `nil` is **omitted from the wire**, never
    /// written as `0`, so a plan with no groups is byte for byte what the
    /// build before this wrote and `WatchPlanRevisions` does not re-push it.
    /// Read leniently: a string, a fraction, a negative, zero or a bool is
    /// not grouped, never a plan that fails to decode.
    public var group: Int?

    public init(name: String, equipment: String? = nil, note: String? = nil,
                sets: [PrescribedSet], lastPerformed: LastPerformed? = nil,
                eachSide: Bool = false, group: Int? = nil) {
        self.name = name
        self.equipment = equipment
        self.note = note
        self.sets = sets
        self.lastPerformed = lastPerformed
        self.eachSide = eachSide
        self.group = Self.groupOf(group)
    }

    private enum CodingKeys: String, CodingKey {
        case name, equipment, note, sets, lastPerformed, eachSide, group
    }

    /// A group number as the wire allows it: a positive integer, or nil.
    /// Coach iPhone's `ExerciseGrouping.groupOf`.
    public static func groupOf(_ value: Int?) -> Int? {
        guard let value, value > 0 else { return nil }
        return value
    }

    // Written out by hand only so `eachSide` can be absent rather than
    // `false`, and `group` read leniently; every other key behaves exactly
    // as the synthesized pair did.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        equipment = try container.decodeIfPresent(String.self, forKey: .equipment)
        note = try container.decodeIfPresent(String.self, forKey: .note)
        sets = try container.decode([PrescribedSet].self, forKey: .sets)
        lastPerformed = try container.decodeIfPresent(LastPerformed.self, forKey: .lastPerformed)
        eachSide = try container.decodeIfPresent(Bool.self, forKey: .eachSide) ?? false
        // `try?`: a group this build cannot read as an integer -- "1", 1.5,
        // true -- costs the lifter the grouping, never the plan.
        group = Self.groupOf((try? container.decodeIfPresent(Int.self, forKey: .group)) ?? nil)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(equipment, forKey: .equipment)
        try container.encodeIfPresent(note, forKey: .note)
        try container.encode(sets, forKey: .sets)
        try container.encodeIfPresent(lastPerformed, forKey: .lastPerformed)
        if eachSide { try container.encode(true, forKey: .eachSide) }
        try container.encodeIfPresent(Self.groupOf(group), forKey: .group)
    }

    /// The kind set `index` is trained as: **an exercise's first set is
    /// always straight**, whatever was sent, because there is no set before
    /// it to drop from or pause after. LIFT for iPhone's `SetKind.at` and
    /// Coach's `PrescriptionTypes.kinds(of:)`. Read here rather than on
    /// `PrescribedSet`, which does not know where it stands.
    public func kind(ofSet index: Int) -> PlanSetKind? {
        guard index > 0, sets.indices.contains(index) else { return nil }
        return sets[index].kind
    }

    /// Whether this exercise says anything about sides at all. A plain
    /// exercise answers `false` and everything below it behaves as it always
    /// has.
    public var prescribesSides: Bool { eachSide || sets.contains { $0.side != nil } }

    /// The sets to actually perform, in order, one entry per set: an
    /// each-side set expands to two — left then right — a set that names a
    /// side is that side once, and everything else is one two-sided set.
    ///
    /// The sided entries of this, in this order, are exactly LIFT for
    /// iPhone's `Prescription.order` (a port of LIFT web's `sides.js`), so
    /// the watch and the phone read one coach's prescription the same way.
    ///
    /// Each entry carries the prescribed row it answers and that row's kind,
    /// so both sides of an each-side drop set are drop sets -- as a sided set
    /// logged on the phone takes its prescription's kind.
    public var plannedSets: [PlannedSet] {
        sets.enumerated().flatMap { row, set -> [PlannedSet] in
            let kind = self.kind(ofSet: row)
            if let side = set.side {
                return [PlannedSet(prescription: set, side: side, kind: kind, row: row)]
            }
            if eachSide {
                return [PlannedSet(prescription: set, side: .left, kind: kind, row: row),
                        PlannedSet(prescription: set, side: .right, kind: kind, row: row)]
            }
            return [PlannedSet(prescription: set, side: nil, kind: kind, row: row)]
        }
    }
}

/// One set to actually perform: the prescription it answers, the side it is
/// done on (`nil` for an ordinary two-sided set), the kind it is trained as
/// (`nil` for straight) and the index of the prescribed row in `sets`.
public struct PlannedSet: Equatable, Sendable {
    public var prescription: PrescribedSet
    public var side: PlanSide?
    /// As trained: never set on an exercise's first row (`kind(ofSet:)`).
    public var kind: PlanSetKind?
    /// Which prescribed row this answers. An each-side row is two planned
    /// sets with the same row, and a superset's round is one row of each
    /// member.
    public var row: Int

    public init(prescription: PrescribedSet, side: PlanSide? = nil,
                kind: PlanSetKind? = nil, row: Int = 0) {
        self.prescription = prescription
        self.side = side
        self.kind = kind
        self.row = row
    }
}

/// How a set follows the one before it (PLAN-FORMAT.md "Set types", flags
/// bits 3-4). **Absent is straight**, as absent is both for a side: there is
/// no `.straight` case to write into a field by accident.
///
/// The two spellings are BACKUP-FORMAT's `kind` and LIFT for iPhone's
/// `SetKind` raw values, so one word means one thing in the phone's store, a
/// backup file and this wire.
public enum PlanSetKind: String, Codable, CaseIterable, Sendable {
    /// Done straight after the set before it, with no rest; normally lighter.
    case drop
    /// Done after a short pause, about 15 seconds; normally the same weight.
    case restPause

    /// The word a set's line ends with, after its side: "30 x 12 · L drop".
    /// LIFT for iPhone's `SetKind.label` and Coach web's `kindLabel`.
    public var label: String { self == .drop ? "drop" : "rest-pause" }

    /// Lenient on the way in, as BACKUP-FORMAT's reader is: case and space
    /// forgiven, and a word this build does not know is straight -- never a
    /// plan that fails to decode, so the weights and reps still arrive.
    public init?(wire: String?) {
        guard let wire else { return nil }
        let folded = wire.trimmingCharacters(in: .whitespaces).lowercased()
        guard let match = Self.allCases.first(where: { $0.rawValue.lowercased() == folded })
        else { return nil }
        self = match
    }
}

/// Which limb a set is for.
///
/// The two spellings are BACKUP-FORMAT's and LIFT for iPhone's `SetSide`
/// raw values, so one word means one thing across the phone's store, a
/// backup file and this wire. **Absent is "both", forever** — there is
/// deliberately no `.both` case to write into a field by accident, exactly
/// as on the phone, and a set written before any of this is a two-sided set
/// and stays one.
public enum PlanSide: String, Codable, CaseIterable, Sendable {
    case left, right

    /// The one character the Now screen, a set row and the phone's own set
    /// rows all use: "30 x 8 · L".
    public var shortLabel: String { self == .left ? "L" : "R" }

    public var opposite: PlanSide { self == .left ? .right : .left }

    /// Lenient on the way in: a word this build does not know is "both", not
    /// a plan that fails to decode. A newer sender adding a third value must
    /// cost a lifter the side, never the weights and reps.
    public init?(wire: String?) {
        guard let wire else { return nil }
        self.init(rawValue: wire.trimmingCharacters(in: .whitespaces).lowercased())
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
    /// The one side this set is for (PLAN-FORMAT.md "Sides": the set tuple's
    /// sixth position). Absent is both, and a both-sides set writes no key,
    /// so a plan with no sides is unchanged. A named side is done on that
    /// side once whether or not its exercise is each side.
    public var side: PlanSide?
    /// How this set follows the one before it: a drop set or rest-pause
    /// (PLAN-FORMAT.md "Set types", flags bits 3-4). Absent is straight, and
    /// a straight set writes no key, so a plan with no set types is
    /// unchanged. A sender never writes one on an exercise's first set, and
    /// a receiver reads one there as straight (`PlanExercise.kind(ofSet:)`)
    /// -- this field carries what arrived, the rule is applied where it is
    /// read, as the phone applies `SetKind.at`.
    public var kind: PlanSetKind?

    public init(weightKg: Double? = nil, reps: Int? = nil,
                rpe: Double? = nil, restSeconds: Int? = nil,
                side: PlanSide? = nil, kind: PlanSetKind? = nil) {
        self.weightKg = weightKg
        self.reps = reps
        self.rpe = rpe
        self.restSeconds = restSeconds
        self.side = side
        self.kind = kind
    }

    private enum CodingKeys: String, CodingKey {
        case weightKg, reps, rpe, restSeconds, side, kind
    }

    // By hand only for `side` and `kind`, which are read leniently: a word
    // this build does not know leaves the set two-sided and straight rather
    // than failing the plan (`PlanSide(wire:)`, `PlanSetKind(wire:)`). Every
    // other key behaves as the synthesized pair did — absent and `null` both
    // decode as nil, and nil encodes as no key.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        weightKg = try container.decodeIfPresent(Double.self, forKey: .weightKg)
        reps = try container.decodeIfPresent(Int.self, forKey: .reps)
        rpe = try container.decodeIfPresent(Double.self, forKey: .rpe)
        restSeconds = try container.decodeIfPresent(Int.self, forKey: .restSeconds)
        let rawSide = (try? container.decodeIfPresent(String.self, forKey: .side)) ?? nil
        side = PlanSide(wire: rawSide)
        let rawKind = (try? container.decodeIfPresent(String.self, forKey: .kind)) ?? nil
        kind = PlanSetKind(wire: rawKind)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(weightKg, forKey: .weightKg)
        try container.encodeIfPresent(reps, forKey: .reps)
        try container.encodeIfPresent(rpe, forKey: .rpe)
        try container.encodeIfPresent(restSeconds, forKey: .restSeconds)
        try container.encodeIfPresent(side, forKey: .side)
        try container.encodeIfPresent(kind, forKey: .kind)
    }

    /// Whether the set prescribes no numbers at all. A side or a kind is not
    /// a number: "one more on the left, you pick the weight" is still an
    /// empty prescription in everything the Now screen draws in big digits.
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

/// How heart rate is said, on the watch and on the phone: both compile this
/// one copy, so the two cannot drift. LIFT for Android and its Wear OS watch
/// say the same words; change them in every build or in none.
///
/// **Shown, never graded.** A number and its unit, with nothing beside it:
/// no zone, no colour, no threshold, no percentage of a maximum heart rate
/// (that needs an age-based guess no build is qualified to make), and nothing
/// about being recovered or ready.
public enum HeartRateWords {

    /// "max 142 bpm", muted, beside a set that has a figure.
    public static func set(maxBpm: Int) -> String {
        "max \(maxBpm) bpm"
    }

    /// "Heart rate: average 118 · max 156 bpm", for a session. Whole beats,
    /// halves away from zero, as a set's figure is rounded.
    public static func session(_ heartRate: SessionHeartRate) -> String {
        "Heart rate: average \(whole(heartRate.averageBpm)) · max \(whole(heartRate.maxBpm)) bpm"
    }

    /// The same line from halves either of which may be absent, as a backup
    /// can carry them: one half alone says only that half ("Heart rate: max
    /// 156 bpm"), and neither is no line at all. LIFT for Android's
    /// `HeartRateLines.session`, word for word. The watch always sends both,
    /// so only a hand-edited or foreign backup ever shows a half.
    public static func session(averageBpm: Double?, maxBpm: Double?) -> String? {
        let parts = [
            averageBpm.flatMap { $0.isFinite && whole($0) > 0 ? "average \(whole($0))" : nil },
            maxBpm.flatMap { $0.isFinite && whole($0) > 0 ? "max \(whole($0))" : nil }
        ].compactMap { $0 }
        return parts.isEmpty ? nil : "Heart rate: \(parts.joined(separator: " · ")) bpm"
    }

    private static func whole(_ bpm: Double) -> Int {
        Int(bpm.rounded(.toNearestOrAwayFromZero))
    }
}
