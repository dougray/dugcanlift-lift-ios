import Foundation
import LiftSync

// Supersets and circuits, as the watch reads them (PLAN-FORMAT.md "Set types";
// the LIFT superproject's `2026-10-28-set-types-design.md`). A port of LIFT for
// iPhone's `ExerciseGrouping` (`Sources/Shared/SetTypes.swift`), which is itself
// Coach web's `prescriptions.js` and Coach iPhone's `PrescriptionTypes.swift`
// rule for rule -- only the reading half, because the watch never edits a plan.
// Port it; do not re-derive it.
//
// Values with no view in them, for the reason `GuidedSession` is one: these
// decide which exercise comes next in a round, and a rule living in a view's
// body cannot be tested.

/// What a grouped exercise is labeled: "Superset A" and "A1". Two exercises
/// are a superset and three or more a circuit; the letters run A, B, C...
/// within the plan and the members are numbered from 1. LIFT for iPhone's
/// `GroupLabel`, word for word.
public struct PlanGroupLabel: Equatable, Sendable {
    /// "Superset A", "Circuit B".
    public var group: String
    /// "A1", "B3".
    public var member: String
    /// Whether this is the group's first exercise.
    public var first: Bool
    public var size: Int

    /// "Superset A · A1", the line over a grouped exercise.
    public var text: String { "\(group) · \(member)" }
}

public enum PlanGrouping {

    /// The group each position belongs to: runs of two or more adjacent equal
    /// numbers become 1, 2, 3... in order of appearance, and everything else
    /// -- a lone number, a number its neighbors do not share, no number at
    /// all -- is nil.
    ///
    /// So `[7, 7, 3, 3, 3]` is `[1, 1, 2, 2, 2]`, and `[1, nil, 1]` is three
    /// ungrouped exercises: the number only has to differ from its neighbors.
    public static func runs(_ numbers: [Int?]) -> [Int?] {
        var out = [Int?](repeating: nil, count: numbers.count)
        var next = 1
        var i = 0
        while i < numbers.count {
            let g = PlanExercise.groupOf(numbers[i])
            var j = i + 1
            if let g { while j < numbers.count && PlanExercise.groupOf(numbers[j]) == g { j += 1 } }
            if g != nil, j - i >= 2 {
                for k in i..<j { out[k] = next }
                next += 1
            }
            i = j
        }
        return out
    }

    /// Spreadsheet letters: 0 is A, 25 Z, 26 AA. A plan with 27 groups is not
    /// likely, but a label must never be blank.
    public static func letters(_ n: Int) -> String {
        var out = ""
        var x = n + 1
        while x > 0 {
            out = String(Character(UnicodeScalar(UInt8(65 + (x - 1) % 26)))) + out
            x = (x - 1) / 26
        }
        return out
    }

    /// Each position's label, or nil when it is not grouped.
    public static func labels(_ numbers: [Int?]) -> [PlanGroupLabel?] {
        let groups = runs(numbers)
        var sizes: [Int: Int] = [:]
        for g in groups.compactMap({ $0 }) { sizes[g, default: 0] += 1 }
        var seen: [Int: Int] = [:]
        return groups.map { g in
            guard let g else { return nil }
            let letter = letters(g - 1)
            seen[g, default: 0] += 1
            let size = sizes[g] ?? 0
            return PlanGroupLabel(group: (size >= 3 ? "Circuit " : "Superset ") + letter,
                                  member: letter + String(seen[g] ?? 0),
                                  first: seen[g] == 1, size: size)
        }
    }
}

extension WorkoutPlan {
    /// Each exercise's group label, parallel to `exercises`: "Superset A ·
    /// A1" over a grouped one, nil over everything else -- which is every
    /// exercise of a plan with no groups.
    public var groupLabels: [PlanGroupLabel?] {
        PlanGrouping.labels(exercises.map(\.group))
    }
}
