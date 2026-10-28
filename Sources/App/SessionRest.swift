import Foundation

/// What ticking a set done starts, once the day knows its supersets, drop sets
/// and rest-pause sets (PLAN-FORMAT.md "Set types", the LIFT superproject's
/// `2026-10-28-set-types-design.md` "The rest timer").
///
/// A value type with no view and no timer in it, the rule `LiftProgression` and
/// `RoutineRemoval` follow: a rule in a view cannot be tested, and this one
/// decides whether somebody rests. `RestTimer` keeps doing exactly what it did;
/// this only says which of its doors to use.
///
/// **The order** is the prescribed one, round by round: an ungrouped exercise
/// is its sets in order; a group is one set of each member, in order, then the
/// next round, and a member that has run out of sets is skipped. Three things
/// change from "ticking a set starts the Settings rest":
///
/// - **Inside a superset round**, while any other set of the same round is not
///   ticked, no rest: the banner says "Next: Seated Cable Rows". The round's
///   last tick starts the full rest.
/// - **The next set to do is a drop set**: no rest, "Drop set next".
/// - **The next set to do is rest-pause**: a 15-second rest.
///
/// "The next set to do" is the first set after the ticked one in that order
/// that is not ticked. With the rest turned off in Settings nothing starts and
/// nothing is said, as before.
enum SessionRest {

    /// Rest-pause is a fixed pause, not a setting (the design's own call).
    static let restPauseSeconds = 15

    struct Exercise: Equatable {
        /// What the banner names: "Next: Seated Cable Rows".
        var name: String
        /// What a rest is before: "Back to Seated Cable Rows (Cable)".
        var restName: String
        /// The logged group number, nil when not grouped. Adjacency decides.
        var group: Int?
        var sets: [SetState]

        init(name: String, restName: String? = nil, group: Int? = nil, sets: [SetState]) {
            self.name = name
            self.restName = restName ?? name
            self.group = group
            self.sets = sets
        }
    }

    struct SetState: Equatable {
        var id: UUID
        var done: Bool
        /// As trained: an exercise's first set is never a drop or rest-pause,
        /// which the caller has already applied (`SetKind.at`).
        var kind: SetKind?

        init(id: UUID = UUID(), done: Bool = false, kind: SetKind? = nil) {
            self.id = id
            self.done = done
            self.kind = kind
        }
    }

    enum After: Equatable {
        /// A rest of this many seconds, before the named exercise.
        case rest(seconds: Int, before: String?)
        /// No rest, and what the banner says instead.
        case noRest(cue: String)
        /// Nothing at all: the rest is turned off.
        case nothing
    }

    /// One place in the order.
    struct Step: Equatable {
        var exercise: Int
        var set: Int
        /// The first exercise of the block -- a group, or an exercise alone.
        var block: Int
        var round: Int
        var grouped: Bool
    }

    /// A logged day, as this rule reads it: each exercise's logged group, and
    /// each set's done tick and kind as trained.
    static func exercises(_ entries: [ExerciseEntry], setTypes: RoutineSetTypes) -> [Exercise] {
        entries.map { entry in
            Exercise(name: entry.name, restName: entry.displayName,
                     group: setTypes.loggedGroups[entry.id],
                     sets: entry.orderedSets.enumerated().map { index, set in
                         SetState(id: set.id, done: set.completedAt != nil,
                                  kind: setTypes.loggedKind(of: set, at: index))
                     })
        }
    }

    /// Every set of the day in the order it is trained.
    static func order(_ exercises: [Exercise]) -> [Step] {
        let groups = ExerciseGrouping.runs(exercises.map(\.group))
        var steps: [Step] = []
        var i = 0
        while i < exercises.count {
            guard let group = groups[i] else {
                for set in exercises[i].sets.indices {
                    steps.append(Step(exercise: i, set: set, block: i, round: set, grouped: false))
                }
                i += 1
                continue
            }
            var end = i
            while end < exercises.count, groups[end] == group { end += 1 }
            let rounds = exercises[i..<end].map(\.sets.count).max() ?? 0
            for round in 0..<rounds {
                for member in i..<end where round < exercises[member].sets.count {
                    steps.append(Step(exercise: member, set: round, block: i, round: round, grouped: true))
                }
            }
            i = end
        }
        return steps
    }

    /// What ticking `setID` done starts. `restSeconds` is Settings' "Rest
    /// between sets", nil when it is off.
    static func after(ticking setID: UUID, in exercises: [Exercise], restSeconds: Int?) -> After {
        guard let restSeconds, restSeconds > 0 else { return .nothing }
        let steps = order(exercises)
        func set(_ step: Step) -> SetState { exercises[step.exercise].sets[step.set] }
        func waiting(_ step: Step) -> Bool { !set(step).done && set(step).id != setID }

        guard let position = steps.firstIndex(where: { set($0).id == setID }) else {
            return .rest(seconds: restSeconds, before: nil)
        }
        let ticked = steps[position]

        // The round is not over while another of its sets is still to do.
        if ticked.grouped, let other = steps.first(where: {
            $0.block == ticked.block && $0.round == ticked.round && waiting($0)
        }) {
            return .noRest(cue: "Next: \(exercises[other.exercise].name)")
        }

        guard let next = steps[(position + 1)...].first(where: waiting) else {
            return .rest(seconds: restSeconds, before: exercises[ticked.exercise].restName)
        }
        switch set(next).kind {
        case .drop?:
            return .noRest(cue: "Drop set next")
        case .restPause?:
            return .rest(seconds: restPauseSeconds, before: exercises[next.exercise].restName)
        case nil:
            // Back to whatever comes next inside a group; otherwise the
            // exercise just ticked, which is what the rest always said.
            let before = next.block == ticked.block ? next.exercise : ticked.exercise
            return .rest(seconds: restSeconds, before: exercises[before].restName)
        }
    }
}
