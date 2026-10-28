import Foundation
import LiftCore

// Set types (PLAN-FORMAT.md "Set types"): supersets and circuits, drop sets and
// rest-pause. Coach web's `coach/prescriptions.js` is the reference
// implementation and LIFT web's `lift/set-types.js` the reader's port of it;
// Coach iPhone's `PrescriptionTypes.swift` is the same port in Swift, and the
// group rules below are its, rule for rule, so a coach and their client read
// the same groups and the same words.
//
//   a group   exercises done round by round -- one set of each, then the rest.
//             Two make a superset, three or more a circuit. On the wire `g`;
//             adjacency makes the group, not the number, so a group of one is
//             no group.
//   a kind    how a set follows the one before it: drop (no rest, normally
//             lighter) or rest-pause (a short pause, normally the same
//             weight). On the wire, flags bits 3-4, OR'd with the side. An
//             exercise's first set has no set before it, so it is always
//             straight.
//
// Tracked and shown, never graded. The imbalance figure and volume read the
// log, never these. Progression reads one thing from them: a drop or
// rest-pause set is not a working set for the next weight (`ProgressionRule`).

// MARK: - A set's kind

/// Drop or rest-pause. `nil` is straight, everywhere: absent is how straight
/// is spelt, in storage and on the wire.
enum SetKind: String, Codable, CaseIterable, Identifiable {
    /// Done straight after the set before it, with no rest; normally lighter.
    case drop
    /// Done after a short pause, about 15 seconds; normally the same weight.
    case restPause

    var id: String { rawValue }

    static let planShift = 3

    /// The word a set's text ends with, after its side: "30 x 12 L drop".
    /// Coach web's `kindLabel`.
    var label: String { self == .drop ? "drop" : "rest-pause" }

    /// The editor's control: "Drop", "Rest-pause".
    var displayName: String { self == .drop ? "Drop" : "Rest-pause" }

    /// What VoiceOver says for the editor's choice.
    var spokenName: String {
        self == .drop ? "Drop set: no rest before it" : "Rest-pause: a short pause before it"
    }

    /// The kind bits 3-4 of a plan tuple's `flags` say, or nil for straight.
    /// **Masked, never compared**: a left-side drop set arrives as 10, and a
    /// reader testing `flags == 8` would call it straight. A missing,
    /// non-integral or negative `flags` is straight; 3 in bits 3-4 is never
    /// written and reads as straight; bit 0 and the side bits are not this
    /// reader's. Coach web's `kindFromFlags`, and the same guard
    /// `PlanSetFlags.sideBits` puts on the value.
    init?(planTuple tuple: [Double?]) {
        guard tuple.count > PlanSetFlags.index, let raw = tuple[PlanSetFlags.index],
              raw.isFinite, raw.rounded() == raw, raw >= 0, raw < 256 else { return nil }
        switch (Int(raw) >> Self.planShift) & 0b11 {
        case 1: self = .drop
        case 2: self = .restPause
        default: return nil
        }
    }

    /// The kind set `index` of an exercise is shown and trained as: the first
    /// set is straight whatever was stored, because there is nothing before it
    /// to drop from or pause after -- which can happen in a log, when the set
    /// before a drop set is deleted. LIFT web's `kindAt`.
    static func at(_ index: Int, _ stored: SetKind?) -> SetKind? {
        index > 0 ? stored : nil
    }
}

// MARK: - Groups, as rules on a list of numbers

/// What a grouped exercise is labelled: "Superset A" and "A1". Two exercises
/// are a superset and three or more a circuit; the letters run A, B, C...
/// within the routine or the day and the members are numbered from 1.
struct GroupLabel: Equatable {
    /// "Superset A", "Circuit B".
    var group: String
    /// "A1", "B3".
    var member: String
    /// Whether this is the group's first exercise.
    var first: Bool
    var size: Int

    /// "Superset A · A1", the line over a grouped exercise.
    var text: String { "\(group) · \(member)" }
}

/// The group rules, over a list of stored group numbers in order. Values, with
/// no store and no view in them, for the reason `LiftProgression` is one: a
/// rule living in a view cannot be tested, and these decide what a live
/// session does round by round. Coach web's `runs`, `groupedWithNext`,
/// `setGroupedWithNext`, `letters` and `groupLabels`, rule for rule.
enum ExerciseGrouping {

    /// A group number as stored: a positive integer, or nil.
    static func groupOf(_ value: Int?) -> Int? {
        guard let value, value > 0 else { return nil }
        return value
    }

    /// The group each position belongs to: runs of two or more adjacent equal
    /// numbers become 1, 2, 3... in order of appearance, and everything else
    /// -- a lone number, a number its neighbours do not share, no number at
    /// all -- is nil.
    ///
    /// So `[7, 7, 3, 3, 3]` is `[1, 1, 2, 2, 2]`, and `[1, nil, 1]` is three
    /// ungrouped exercises: the number only has to differ from its neighbours.
    static func runs(_ numbers: [Int?]) -> [Int?] {
        var out = [Int?](repeating: nil, count: numbers.count)
        var next = 1
        var i = 0
        while i < numbers.count {
            let g = groupOf(numbers[i])
            var j = i + 1
            if let g { while j < numbers.count && groupOf(numbers[j]) == g { j += 1 } }
            if g != nil, j - i >= 2 {
                for k in i..<j { out[k] = next }
                next += 1
            }
            i = j
        }
        return out
    }

    /// Whether position `i` and the one after it are in the same group -- the
    /// "Superset with next" toggle's state.
    static func groupedWithNext(_ numbers: [Int?], at i: Int) -> Bool {
        let groups = runs(numbers)
        guard i >= 0, i + 1 < groups.count, let a = groups[i] else { return false }
        return groups[i + 1] == a
    }

    /// Join position `i` to the next, or split them. Joining takes the whole
    /// group the next exercise is in, so "Superset with next" on the exercise
    /// before a superset makes a circuit of three, and joining two groups
    /// makes one. Splitting keeps the exercises before the split in their
    /// group and gives the rest one of their own, so splitting a circuit of
    /// three after its first leaves a superset. Either way the result is
    /// renumbered: a group left with one member is gone. The last position
    /// has no next, and asking changes nothing.
    static func settingGroupedWithNext(_ numbers: [Int?], at i: Int, _ on: Bool) -> [Int?] {
        guard i >= 0, i + 1 < numbers.count else { return numbers }
        var list = runs(numbers)
        let a = list[i]
        let b = list[i + 1]
        let fresh = (list.compactMap { $0 }.max() ?? 0) + 1
        if on {
            if let a, a == b { return list }
            let target = a ?? b ?? fresh
            list[i] = target
            list[i + 1] = target
            var j = i + 2
            while let b, j < list.count, list[j] == b {
                list[j] = target
                j += 1
            }
        } else {
            guard let a, a == b else { return list }
            var j = i + 1
            while j < list.count, list[j] == a {
                list[j] = fresh
                j += 1
            }
        }
        return runs(list)
    }

    /// Spreadsheet letters: 0 is A, 25 Z, 26 AA. A day with 27 groups is not
    /// likely, but a label must never be blank.
    static func letters(_ n: Int) -> String {
        var out = ""
        var x = n + 1
        while x > 0 {
            out = String(Character(UnicodeScalar(UInt8(65 + (x - 1) % 26)))) + out
            x = (x - 1) / 26
        }
        return out
    }

    /// Each position's label, or nil when it is not grouped.
    static func labels(_ numbers: [Int?]) -> [GroupLabel?] {
        let groups = runs(numbers)
        var sizes: [Int: Int] = [:]
        for g in groups.compactMap({ $0 }) { sizes[g, default: 0] += 1 }
        var seen: [Int: Int] = [:]
        return groups.map { g in
            guard let g else { return nil }
            let letter = letters(g - 1)
            seen[g, default: 0] += 1
            let size = sizes[g] ?? 0
            return GroupLabel(group: (size >= 3 ? "Circuit " : "Superset ") + letter,
                              member: letter + String(seen[g] ?? 0),
                              first: seen[g] == 1, size: size)
        }
    }

    /// "Superset A · Circuit B": every group a list holds, once each, in
    /// order -- the routine list's line. Empty when nothing is grouped.
    static func summary(_ numbers: [Int?]) -> String {
        labels(numbers).compactMap { $0?.first == true ? $0?.group : nil }.joined(separator: " · ")
    }
}

// MARK: - Where they are kept

/// A routine's set types, and a started day's copy of them.
///
/// **Not on the routine.** `RoutineExercise` and `RoutinePrescribedSet` are
/// LiftKit's shared `@Model`s, and a property on them is a schema change here
/// that would mean freezing all three routine models in every version since
/// V3, plus one for Coach iOS. So this is a preference-sized side-car in
/// `UserDefaults`, exactly as `PlanSides` is: keyed by the routine's exercise
/// and set ids, written when a coach's plan is accepted or the lifter sets one
/// in the routine editor; and keyed by the logged `ExerciseEntry` and
/// `SetEntry` ids once a session starts -- a copy, not a link back, so a
/// session keeps its rounds when the routine is edited or deleted.
///
/// **Storage holds groups as the wire numbers them**: runs renumbered 1, 2,
/// 3..., a group of one removed, because every write to a routine's groups
/// goes through `ExerciseGrouping`. A logged day's numbers are offset per
/// routine started, so two routines started on one day never merge into one
/// group by accident; `runs` renumbers them for display.
///
/// It suggests how to train; the log records. Nothing here reaches a coach:
/// SHARE-FORMAT carries no set type, and a drop set logged here goes to them
/// as an ordinary set with its real numbers.
struct RoutineSetTypes: Codable, Equatable {

    static let storageKey = "routineSetTypes"

    /// `RoutineExercise.id` -> its group. Absent is not grouped.
    var groups: [UUID: Int] = [:]
    /// `RoutinePrescribedSet.id` -> its kind. Absent is straight.
    var kinds: [UUID: SetKind] = [:]
    /// `ExerciseEntry.id` -> the group it was started in.
    var loggedGroups: [UUID: Int] = [:]
    /// `SetEntry.id` -> the kind it was started as.
    var loggedKinds: [UUID: SetKind] = [:]

    init() {}

    private enum CodingKeys: String, CodingKey { case groups, kinds, loggedGroups, loggedKinds }

    /// Lenient: a missing half is empty, so a value written by a later build
    /// with one more key, or an earlier one with fewer, still reads.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        groups = (try? c.decodeIfPresent([UUID: Int].self, forKey: .groups)) ?? [:]
        kinds = (try? c.decodeIfPresent([UUID: SetKind].self, forKey: .kinds)) ?? [:]
        loggedGroups = (try? c.decodeIfPresent([UUID: Int].self, forKey: .loggedGroups)) ?? [:]
        loggedKinds = (try? c.decodeIfPresent([UUID: SetKind].self, forKey: .loggedKinds)) ?? [:]
    }

    // MARK: Storage

    static func load(from defaults: UserDefaults = .standard) -> RoutineSetTypes {
        guard let data = defaults.data(forKey: storageKey) else { return RoutineSetTypes() }
        return decode(data)
    }

    /// What `@AppStorage` holds, read the way `load` reads it.
    static func decode(_ data: Data) -> RoutineSetTypes {
        (try? JSONDecoder().decode(RoutineSetTypes.self, from: data)) ?? RoutineSetTypes()
    }

    func save(to defaults: UserDefaults = .standard) {
        guard let data = encoded() else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    /// The bytes `save` writes, for a view holding them in `@AppStorage`.
    func encoded() -> Data? { try? JSONEncoder().encode(self) }

    // MARK: A routine's

    /// The stored group numbers of a routine's exercises, in order.
    func storedGroups(_ exercises: [RoutineExercise]) -> [Int?] {
        exercises.map { groups[$0.id] }
    }

    func labels(_ exercises: [RoutineExercise]) -> [GroupLabel?] {
        ExerciseGrouping.labels(storedGroups(exercises))
    }

    func groupedWithNext(_ exercises: [RoutineExercise], at index: Int) -> Bool {
        ExerciseGrouping.groupedWithNext(storedGroups(exercises), at: index)
    }

    /// The kind each of an exercise's sets is, in order; the first is always
    /// straight.
    func kinds(of exercise: RoutineExercise) -> [SetKind?] {
        exercise.orderedSets.enumerated().map { SetKind.at($0.offset, kinds[$0.element.id]) }
    }

    /// Whether the editor shows the Straight / Drop / Rest-pause control
    /// without being asked: a set after the first already has a kind.
    func showsKinds(_ exercise: RoutineExercise) -> Bool {
        kinds(of: exercise).contains { $0 != nil }
    }

    /// Join exercise `index` to the next, or split them.
    mutating func setGroupedWithNext(_ on: Bool, at index: Int, in exercises: [RoutineExercise]) {
        write(ExerciseGrouping.settingGroupedWithNext(storedGroups(exercises), at: index, on),
              to: exercises)
    }

    /// Writes a routine's groups as given, renumbered as the wire would: a
    /// group of one is not kept.
    mutating func write(_ numbers: [Int?], to exercises: [RoutineExercise]) {
        for (exercise, group) in zip(exercises, ExerciseGrouping.runs(numbers)) {
            groups[exercise.id] = group
        }
    }

    /// `nil` is straight: the entry goes, rather than a "straight" being
    /// written down. An exercise's first set never takes one.
    mutating func setKind(_ kind: SetKind?, for set: RoutinePrescribedSet, in exercise: RoutineExercise) {
        guard let index = exercise.orderedSets.firstIndex(where: { $0.id == set.id }) else { return }
        kinds[set.id] = SetKind.at(index, kind)
    }

    /// Drops a routine's groups and kinds -- `RoutineRemoval`'s sweep. The
    /// logged copies stay with the sessions that happened.
    mutating func sweep(exerciseIDs: Set<UUID>, setIDs: Set<UUID>) {
        for id in exerciseIDs { groups.removeValue(forKey: id) }
        for id in setIDs { kinds.removeValue(forKey: id) }
    }

    // MARK: A logged day's

    /// The group labels of a day's exercises, in order.
    func loggedLabels(_ exercises: [ExerciseEntry]) -> [GroupLabel?] {
        ExerciseGrouping.labels(exercises.map { loggedGroups[$0.id] })
    }

    /// The kind a logged set is trained as, at its place in its exercise.
    func loggedKind(of set: SetEntry, at index: Int) -> SetKind? {
        SetKind.at(index, loggedKinds[set.id])
    }

    /// The first logged group number free on a day, so a routine started
    /// beside another never joins its groups to the other's.
    func nextLoggedGroupOffset(_ exercises: [ExerciseEntry]) -> Int {
        exercises.compactMap { loggedGroups[$0.id] }.max() ?? 0
    }
}
