import Foundation
import LiftCore

/// A coach's per-side prescription (PLAN-FORMAT.md "Sides"): an exercise can
/// be **each side** -- every prescribed set done on both sides, so "3 x 8 each
/// side" is six sets, three a side -- and a set can **name a side**, done on
/// that side once. Both arrive in a plan link (`b: 1`, and the set tuple's
/// sixth position read through `LiftCore.PlanSetFlags`).
///
/// **Where it is kept.** Not on `RoutineExercise` / `RoutinePrescribedSet`:
/// those are LiftKit's shared `@Model`s, and a property on them is a schema
/// change here that would mean freezing all three routine models in every
/// version since V3 (see `LiftSchemaVersions.swift`), plus one for Coach iOS.
/// Nor on `ExerciseEntry`, which would be a V9 for a suggestion. It is a
/// preference-sized side-car in `UserDefaults`, the way `perSideExercises`
/// and `WatchPlanPin` already are: keyed by the routine's exercise and set ids
/// when a plan is accepted, and by the logged `ExerciseEntry` id once a
/// session starts -- a copy, not a link back to the routine, so the targets
/// survive the routine being edited or deleted and a relaunch.
///
/// **It suggests; the log records.** Progression, the imbalance figure and
/// volume read `SetEntry`, never this.
struct PlanSides: Codable, Equatable {

    static let storageKey = "coachPlanSides"

    /// `RoutineExercise.id` of every exercise a coach made each side.
    var eachSide: Set<UUID> = []
    /// `RoutinePrescribedSet.id` -> the side it names. Absent is both.
    var sides: [UUID: SetSide] = [:]
    /// `ExerciseEntry.id` -> the prescription it was started from, kept only
    /// when that prescription says something about sides.
    var logged: [UUID: Prescription] = [:]

    // MARK: Storage

    static func load(from defaults: UserDefaults = .standard) -> PlanSides {
        guard let data = defaults.data(forKey: storageKey),
              let value = try? JSONDecoder().decode(PlanSides.self, from: data) else { return PlanSides() }
        return value
    }

    func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    /// The prescription a logged exercise was started from, if it had sides.
    static func prescription(for entryID: UUID, in defaults: UserDefaults = .standard) -> Prescription? {
        load(from: defaults).logged[entryID]
    }

    // MARK: A routine's sides

    func isEachSide(_ exercise: RoutineExercise) -> Bool { eachSide.contains(exercise.id) }

    func side(of set: RoutinePrescribedSet) -> SetSide? { sides[set.id] }

    /// The routine exercise's prescription with its sides, or nil when it says
    /// nothing about sides -- a two-sided exercise is started as it always was.
    func prescription(for exercise: RoutineExercise) -> Prescription? {
        let prescription = Prescription(
            eachSide: isEachSide(exercise),
            sets: exercise.orderedSets.map { CoachPrescribedSet($0, side: side(of: $0)) })
        return prescription.prescribesSides ? prescription : nil
    }
}

extension SetSide {
    /// From `PlanSetFlags.sideBits`: `1` left, `2` right, anything else both.
    init?(planSideBits bits: Int?) {
        switch bits {
        case 1?: self = .left
        case 2?: self = .right
        default: return nil
        }
    }
}

/// One prescribed set as a coach wrote it, in LIFT's units: kilograms, and
/// nil for anything not prescribed.
struct CoachPrescribedSet: Codable, Equatable {
    var weightKg: Double?
    var reps: Int?
    var rpe: Double?
    var durationSec: Int?
    var distanceMeters: Double?
    var side: SetSide?

    init(weightKg: Double? = nil, reps: Int? = nil, rpe: Double? = nil,
         durationSec: Int? = nil, distanceMeters: Double? = nil, side: SetSide? = nil) {
        self.weightKg = weightKg
        self.reps = reps
        self.rpe = rpe
        self.durationSec = durationSec
        self.distanceMeters = distanceMeters
        self.side = side
    }

    init(_ set: RoutinePrescribedSet, side: SetSide?) {
        self.init(weightKg: set.targetWeightKg, reps: set.targetReps, rpe: set.targetRPE,
                  durationSec: set.targetDurationSec, distanceMeters: set.targetDistanceMeters,
                  side: side)
    }
}

/// What a coach asked of one exercise, and the rules for reading it against
/// what has been logged. A port of LIFT web's `sides.js` ("a coach's
/// prescription"): same functions, same rules, so the three LIFT builds
/// suggest the same side and print the same target.
struct Prescription: Codable, Equatable {
    var eachSide: Bool
    var sets: [CoachPrescribedSet]

    struct Targets: Equatable {
        var left = 0
        var right = 0
        var both = 0
    }

    /// Whether this says anything about sides at all.
    var prescribesSides: Bool { eachSide || sets.contains { $0.side != nil } }

    /// Sets asked for per side, and two-sided ones. An each-side set counts
    /// once on each side; a named set once on its own side. Each side plus one
    /// extra left set is left 4, right 3.
    var targets: Targets {
        var out = Targets()
        for set in sets {
            switch set.side {
            case .left?: out.left += 1
            case .right?: out.right += 1
            case nil:
                if eachSide { out.left += 1; out.right += 1 } else { out.both += 1 }
            }
        }
        return out
    }

    /// The sided sets in the order the coach wrote them: an each-side set is
    /// left then right, a named set its own side. Two-sided sets have no place.
    private var order: [(side: SetSide, set: CoachPrescribedSet)] {
        sets.flatMap { set -> [(side: SetSide, set: CoachPrescribedSet)] in
            if let side = set.side { return [(side, set)] }
            return eachSide ? [(.left, set), (.right, set)] : []
        }
    }

    /// The side of the next prescribed set nothing logged has filled yet, or
    /// nil when every sided set is filled (the caller then offers whichever
    /// side is behind, as it always has). Logged sets fill prescribed ones side
    /// by side, in order, so three lefts logged first leave the first right
    /// unfilled.
    func nextSide(after logged: [SetSide?]) -> SetSide? {
        var have = [SetSide.left: 0, .right: 0]
        for side in logged.compactMap({ $0 }) { have[side, default: 0] += 1 }
        var used = [SetSide.left: 0, .right: 0]
        for entry in order {
            if used[entry.side, default: 0] >= have[entry.side, default: 0] { return entry.side }
            used[entry.side, default: 0] += 1
        }
        return nil
    }

    /// The prescribed set the next set on `side` answers, to prefill it from,
    /// or nil once that side's prescription is used up.
    func setFor(side: SetSide?, after logged: [SetSide?]) -> CoachPrescribedSet? {
        guard let side else { return nil }
        let mine = order.filter { $0.side == side }
        let count = logged.filter { $0 == side }.count
        return count < mine.count ? mine[count].set : nil
    }

    /// "L 0/3 · R 0/3": logged against asked, per side. Over is shown as over
    /// -- "L 4/3" -- because it is what happened and the coach should see it.
    /// A side the plan does not ask for appears only once something is logged
    /// on it, and two-sided sets are counted when there are any. Empty when
    /// the plan says nothing about sides, so the caller keeps its plain count.
    func targetsLabel(logged: [SetSide?]) -> String {
        let t = targets
        guard t.left > 0 || t.right > 0 else { return "" }
        let left = logged.filter { $0 == .left }.count
        let right = logged.filter { $0 == .right }.count
        let both = logged.filter { $0 == nil }.count
        var parts: [String] = []
        for (side, asked, have) in [(SetSide.left, t.left, left), (.right, t.right, right)] {
            if asked > 0 { parts.append("\(side.shortLabel) \(have)/\(asked)") }
            else if have > 0 { parts.append("\(side.shortLabel) \(have)") }
        }
        if t.both > 0 { parts.append("\(both)/\(t.both) both") }
        else if both > 0 { parts.append("\(both) both") }
        return parts.joined(separator: " · ")
    }
}
