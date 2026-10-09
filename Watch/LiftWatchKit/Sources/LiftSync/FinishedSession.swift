import Foundation

/// A workout that was actually performed, whole, as it travels home on
/// `SESSION_FINISHED`.
///
/// This is the `session` payload of
/// `Watch/contracts/workout-sync.schema.json`. The watch builds it when the
/// lifter taps Finish and the phone stores it as an ordinary workout, and
/// both apps compile this one definition, so the two cannot disagree about a
/// key. `FinishedSessionWireTests` pins the JSON spellings and
/// `SchemaConformanceTests` checks them against the schema file itself.
///
/// **Why the whole session rather than a set at a time.** The schema left
/// room for a streaming `SET_LOGGED`, and the guided-session spec calls it
/// optional. It is not here, on purpose: a phone in a locker is not
/// reachable, so every streamed message would be lost and only the queued
/// transport (`transferUserInfo`) would carry anything — and a design whose
/// offline path is the one nobody exercises is a design that loses work. A
/// session that arrives whole is one message and one reconciliation, under
/// the revision rule this contract already has. `WORKOUT_EDITED` is still
/// sent per edit, as it always was, and is still only a notification.
///
/// Identity lives on the envelope, not in here: the envelope's `workoutId`
/// is the session's id and its `revision` is the draft's revision, so a
/// resend, a queued copy arriving second and a later edit all reconcile
/// under "newer revision wins" with nothing new to reason about.
public struct FinishedSession: Codable, Equatable, Sendable {

    public var name: String
    /// The training style the session was logged under, as a plain string
    /// rather than an enum: the two apps' rosters are not identical (the
    /// watch has four styles, the phone six), and a word a receiver does not
    /// know must cost the style, never the session. Absent when the sender
    /// has none.
    public var focus: String?
    /// The local calendar day this session belongs to, `yyyy-MM-dd`, as the
    /// **sender's** clock read it when the session started. A session that
    /// runs past midnight belongs to the day it began. The receiver decides
    /// how far to trust it — two devices' clocks are not comparable, which
    /// is exactly why reconciliation is by `revision` and not by a date.
    public var performedOn: String
    public var startedAt: Date
    public var finishedAt: Date
    public var exercises: [PerformedExercise]

    public init(name: String, focus: String? = nil, performedOn: String,
                startedAt: Date, finishedAt: Date, exercises: [PerformedExercise]) {
        self.name = name
        self.focus = focus
        self.performedOn = performedOn
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.exercises = exercises
    }

    /// Every set of every exercise, in order.
    public var allSets: [PerformedSet] { exercises.flatMap(\.sets) }

    /// Warmups excluded, as everywhere else in both apps.
    public var totalVolumeKg: Double {
        allSets.reduce(0) { $0 + ($1.isWarmup ? 0 : Double($1.reps) * $1.weightKg) }
    }
}

/// One exercise as it was trained.
public struct PerformedExercise: Codable, Equatable, Sendable {
    public var name: String
    /// Omitted rather than empty when there is none: a lift's identity is
    /// name *and* equipment, and "" is not an equipment.
    public var equipment: String?
    public var note: String?
    public var sets: [PerformedSet]

    public init(name: String, equipment: String? = nil, note: String? = nil,
                sets: [PerformedSet]) {
        self.name = name
        self.equipment = equipment
        self.note = note
        self.sets = sets
    }
}

/// One set as it was performed.
///
/// Unlike `PrescribedSet`, whose every field is optional because a
/// prescription is often partial, a performed set's `weightKg` and `reps`
/// are **recorded values**: 0 kg is a bodyweight set and not a blank, and
/// both apps' stores hold them as non-optional numbers already. Everything
/// else is still absent-when-unknown, and `warmup` is omitted rather than
/// written `false`.
public struct PerformedSet: Codable, Equatable, Sendable {
    /// KILOGRAMS, as everywhere on this contract.
    public var weightKg: Double
    public var reps: Int
    /// Absent when the lifter did not rate the set. Never zero, which is not
    /// a rating.
    public var rpe: Double?
    /// Omitted from the wire when false, so a session of working sets is
    /// byte for byte what a sender that predates this key wrote.
    public var isWarmup: Bool
    /// The limb this set was actually performed on. **Absent is "both",
    /// forever** — the same one word `PrescribedSet.side`, `DraftSet.side`
    /// and the phone's `SetEntry.sideRaw` use, so a side means one thing in
    /// a plan, in a log, in a backup and here.
    public var side: PlanSide?
    /// When the set was logged. Absent for a set that was entered but never
    /// completed.
    public var completedAt: Date?

    public init(weightKg: Double, reps: Int, rpe: Double? = nil,
                isWarmup: Bool = false, side: PlanSide? = nil,
                completedAt: Date? = nil) {
        self.weightKg = weightKg
        self.reps = reps
        self.rpe = rpe
        self.isWarmup = isWarmup
        self.side = side
        self.completedAt = completedAt
    }

    private enum CodingKeys: String, CodingKey {
        case weightKg, reps, rpe
        case isWarmup = "warmup"
        case side, completedAt
    }

    // Written out by hand for two keys, and two only: `warmup`, which is
    // absent rather than `false`, and `side`, which is read leniently — a
    // word this build does not know leaves the set two-sided rather than
    // failing the whole session (`PlanSide(wire:)`). A session is the only
    // copy of somebody's work; nothing here may throw over a detail.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        weightKg = try container.decode(Double.self, forKey: .weightKg)
        reps = try container.decode(Int.self, forKey: .reps)
        rpe = try container.decodeIfPresent(Double.self, forKey: .rpe)
        isWarmup = try container.decodeIfPresent(Bool.self, forKey: .isWarmup) ?? false
        let rawSide = (try? container.decodeIfPresent(String.self, forKey: .side)) ?? nil
        side = PlanSide(wire: rawSide)
        completedAt = try container.decodeIfPresent(Date.self, forKey: .completedAt)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(weightKg, forKey: .weightKg)
        try container.encode(reps, forKey: .reps)
        try container.encodeIfPresent(rpe, forKey: .rpe)
        if isWarmup { try container.encode(true, forKey: .isWarmup) }
        try container.encodeIfPresent(side, forKey: .side)
        try container.encodeIfPresent(completedAt, forKey: .completedAt)
    }
}

/// The one place a `yyyy-MM-dd` day key on this wire is produced.
///
/// `scheduledFor`, `performedOn` and `LastPerformed.performedOn` are all the
/// same shape, and it is the shape LIFT for iPhone's `DayKey` and
/// PLAN-FORMAT.md both use. Written from `Calendar` components rather than a
/// `DateFormatter`, because a formatter carries a locale and a calendar of
/// its own and this key is neither translated nor negotiable.
///
/// **Local, always.** A day key is the day the person was in, not a UTC one,
/// and day arithmetic goes through `Calendar` for the same reason LIFT's own
/// does: subtracting 86,400 seconds repeats a day across a DST fall-back.
public enum WireDay {

    public static func key(for date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = parts.year, let month = parts.month, let day = parts.day else { return "" }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }
}
