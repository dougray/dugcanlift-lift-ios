import Foundation
import LiftSync

/// Where the lifter is inside a pushed plan: which exercise, which set of it,
/// which side that set is for, and what to do when a set is logged.
///
/// A value type with no view in it, for the reason `RestTimer` is one: this
/// decides what the Now screen says and when the next exercise starts, and a
/// rule living in a view's `@State` cannot be tested. `GuidedSessionTests`
/// pins it.
///
/// It tracks *position*, never the sets themselves. The sets logged against a
/// plan are ordinary `DraftSet`s on an ordinary `WorkoutDraft`, so nothing
/// downstream — revision, outbox, `SESSION_FINISHED` — knows a plan existed.
///
/// **Sides.** A coach can say an exercise is each side, or name a side on one
/// set (PLAN-FORMAT.md "Sides"). An each-side exercise is then twice the sets
/// — "3 x 8 each side" reads 3/6, not 3/3 — and each one is offered on a
/// side. *Which* side is LIFT for iPhone's rule, ported: the side of the
/// first prescribed sided set nothing logged has filled yet, and past the
/// prescription whichever side has fewer sets logged, left breaking a tie. A
/// plan that says nothing about sides behaves exactly as it always has.
///
/// **Set types.** A coach can group exercises into a superset or circuit and
/// mark a set drop or rest-pause (PLAN-FORMAT.md "Set types"). The order and
/// the rest are LIFT for iPhone's live-session rule, `SessionRest`, ported:
/// a group is trained round by round -- one prescribed set of each member, in
/// order, skipping a member that has run out -- with no rest inside a round
/// and the full rest after its last set; a drop set has no rest before it and
/// a rest-pause set 15 seconds. A plan with no groups and no kinds behaves
/// exactly as it always has.
public struct GuidedSession: Equatable, Sendable {

    /// Rest-pause is a fixed pause, not a setting: LIFT for iPhone's
    /// `SessionRest.restPauseSeconds`, the set-types design's own call.
    public static let restPauseSeconds = 15

    /// What logging a set starts. LIFT for iPhone's `SessionRest.After`,
    /// less the case for a rest turned off in Settings, which the watch does
    /// not have.
    public enum Rest: Equatable, Sendable {
        /// The ordinary rest: what the set just performed prescribed, or the
        /// watch's own default when it prescribed none.
        case full
        /// A short, fixed rest before a rest-pause set.
        case short(seconds: Int)
        /// No rest, and what the Now screen says instead: "Next: Seated
        /// Cable Rows" inside a round, "Drop set next" before a drop set.
        case none(cue: String)
    }

    public let plan: WorkoutPlan

    /// The sides of the sets logged against each exercise, in the order they
    /// were logged, parallel to `plan.exercises`. `nil` is a two-sided set,
    /// which is every set of a plan with no sides.
    ///
    /// The sides rather than a count, because the side to offer next is read
    /// from what was actually logged, not from what was prescribed: the
    /// prescription suggests and the log records, on the wrist exactly as on
    /// the phone.
    public private(set) var loggedSides: [[PlanSide?]]
    public private(set) var exerciseIndex: Int
    /// What the last `recordSet(on:)` started; `nil` before any set.
    public private(set) var restAfterLastSet: Rest?

    public init(plan: WorkoutPlan) {
        let empty = Array(repeating: [PlanSide?](), count: plan.exercises.count)
        self.plan = plan
        self.loggedSides = empty
        // An exercise prescribing no sets at all is already done, so the
        // session opens on the first one that actually asks for something.
        self.exerciseIndex = Self.nextUnfinished(from: 0, plan: plan, logged: empty) ?? 0
    }

    /// Sets completed per exercise, parallel to `plan.exercises`.
    public var completedSets: [Int] { loggedSides.map(\.count) }

    // MARK: - Where we are

    /// The index of the exercise being trained, or `nil` once the plan is
    /// done — so a caller mapping position onto its own list cannot read
    /// `exerciseIndex` past the end of a finished session.
    public var currentExerciseIndex: Int? {
        guard !isComplete, plan.exercises.indices.contains(exerciseIndex) else { return nil }
        return exerciseIndex
    }

    public var currentExercise: PlanExercise? {
        guard !isComplete, plan.exercises.indices.contains(exerciseIndex) else { return nil }
        return plan.exercises[exerciseIndex]
    }

    /// 0-based index of the set about to be performed, within the current
    /// exercise's `plannedSets` — the sets to *perform*, so an each-side
    /// exercise's three prescribed rows are six positions. Clamped to the
    /// last one once the exercise is finished, so a caller reading a
    /// prescription after the final set gets the final set's.
    public var currentSetIndex: Int {
        guard let exercise = currentExercise else { return 0 }
        return min(loggedSides[exerciseIndex].count, max(0, exercise.plannedSets.count - 1))
    }

    /// 1-based, for "3/5".
    public var currentSetNumber: Int {
        guard let exercise = currentExercise else { return 0 }
        return min(loggedSides[exerciseIndex].count + 1, exercise.plannedSets.count)
    }

    public var currentSetCount: Int { currentExercise?.plannedSets.count ?? 0 }

    /// "3/5" as the design spec draws it, and "3/6 · L" once a side is in
    /// play — the position and the side the next set is for in one line,
    /// because together they are the one answer to "what am I doing now".
    ///
    /// A drop or rest-pause set adds its word after the side, the order the
    /// phone's set rows read in: "2/4 · drop", "5/6 · L rest-pause". It goes
    /// here rather than in the big prescription line, where "rest-pause"
    /// would shrink the digits past reading mid-set.
    public var positionText: String {
        guard currentExercise != nil else { return "" }
        let position = "\(currentSetNumber)/\(currentSetCount)"
        let marks = [currentSide?.shortLabel, currentKind?.label].compactMap { $0 }
        guard !marks.isEmpty else { return position }
        return "\(position) · \(marks.joined(separator: " "))"
    }

    /// The superset or circuit the current exercise is in, as LIFT and Coach
    /// both write it: "Superset A · A1", "Circuit B · B3". `nil` for an
    /// exercise that is not grouped.
    public var currentGroupLabel: PlanGroupLabel? {
        guard let index = currentExerciseIndex else { return nil }
        let labels = plan.groupLabels
        return labels.indices.contains(index) ? labels[index] : nil
    }

    /// How the next set follows the one before it -- drop or rest-pause --
    /// or `nil` for a straight set, and for any set past what was prescribed:
    /// an extra set repeats the numbers, not the instruction to strip the bar.
    public var currentKind: PlanSetKind? {
        guard let exercise = currentExercise else { return nil }
        return Self.nextPlanned(for: exercise, logged: loggedSides[exerciseIndex])?.kind
    }

    /// The side the next set is to be performed on, or `nil` when this
    /// exercise says nothing about sides.
    ///
    /// A port of the phone's `Prescription.nextSide(after:)` with the
    /// fallback its caller gives it (`ExerciseEntry.nextSide`): the first
    /// prescribed sided set that what has been logged has not filled, and
    /// once the prescription is used up, whichever side is behind. So an
    /// each-side exercise alternates L, R, L, R and an extra set past the
    /// plan lands on the side that is owed one.
    ///
    /// The fallback is only for an each-side exercise, because that is the
    /// one the lifter is doing a limb at a time throughout. A bench press
    /// with one right-side set in it stops asking about sides the moment
    /// that set is logged — the phone's `pendingNamedSide` exactly, where
    /// `eachSide` stands in for the lifter's own per-side preference, which
    /// is a phone screen the watch does not have.
    public var currentSide: PlanSide? {
        guard let exercise = currentExercise else { return nil }
        return Self.side(for: exercise, logged: loggedSides[exerciseIndex])
    }

    /// The prescription the next set answers. With sides in play that is the
    /// next unfilled prescribed set *on that side*, so three lefts logged
    /// first still leave the first right's numbers for the first right set.
    public var currentPrescription: PrescribedSet? {
        guard let exercise = currentExercise else { return nil }
        let logged = loggedSides[exerciseIndex]
        if let next = Self.nextPlanned(for: exercise, logged: logged) { return next.prescription }
        let planned = exercise.plannedSets
        guard let side = Self.side(for: exercise, logged: logged) else {
            guard planned.indices.contains(currentSetIndex) else { return nil }
            return planned[currentSetIndex].prescription
        }
        // Past what the coach asked for on this side: the last thing they did
        // ask for there, which is what the lifter is repeating.
        return planned.last(where: { $0.side == side })?.prescription ?? planned.last?.prescription
    }

    /// The planned set the next one answers, or `nil` once what was logged
    /// has used the prescription up. With sides in play that is the next
    /// unfilled planned set *on the side being offered*; without them, the
    /// next by count, as it always was.
    private static func nextPlanned(for exercise: PlanExercise,
                                    logged: [PlanSide?]) -> PlannedSet? {
        let planned = exercise.plannedSets
        guard let side = side(for: exercise, logged: logged) else {
            return planned.indices.contains(logged.count) ? planned[logged.count] : nil
        }
        let onSide = planned.filter { $0.side == side }
        let done = logged.filter { $0 == side }.count
        return onSide.indices.contains(done) ? onSide[done] : nil
    }

    public var isComplete: Bool {
        Self.nextUnfinished(from: 0, plan: plan, logged: loggedSides) == nil
    }

    /// Sets done across the whole plan, for a progress line.
    public var completedSetCount: Int { loggedSides.reduce(0) { $0 + $1.count } }

    // MARK: - Moving

    /// Records one completed set against the current exercise and advances
    /// when that exercise has had all of its, returning the prescription that
    /// was just performed — which is where the rest interval comes from.
    ///
    /// `side` is the side the set was actually logged on, which the caller
    /// takes from the lifter's own choice — `currentSide` is only what that
    /// choice starts at. A set recorded with no side is a two-sided set, and
    /// that is every set of a plan with no sides.
    ///
    /// Logging more sets than were prescribed is not an error: the count
    /// keeps rising, the exercise is finished either way, and the extra set
    /// is on the draft like any other. A plan is a prescription, not a limit.
    ///
    /// Where it goes next, and what rest it starts (`restAfterLastSet`), are
    /// LIFT for iPhone's `SessionRest` rules over the order `order(_:)`
    /// gives: inside a round that is not over, the next member with a set in
    /// it and no rest; otherwise the next set in order, with no rest before a
    /// drop set, 15 seconds before a rest-pause set, and the full rest
    /// before anything else. A plan with no groups and no kinds goes where it
    /// always went and always rests in full.
    @discardableResult
    public mutating func recordSet(on side: PlanSide? = nil) -> PrescribedSet? {
        guard let exercise = currentExercise else { return nil }
        let performed = currentPrescription
        // The planned set this one answers, read before it is logged.
        let answered = Self.nextPlanned(for: exercise, logged: loggedSides[exerciseIndex])
        loggedSides[exerciseIndex].append(side)

        let steps = Self.order(plan)
        guard let answered,
              let position = steps.firstIndex(where: {
                  $0.exercise == exerciseIndex && $0.row == answered.row
              })
        else {
            // Past the prescription: an extra set. The next exercise with
            // sets owed, and the ordinary rest, as before set types.
            if let next = Self.nextUnfinished(from: exerciseIndex, plan: plan, logged: loggedSides) {
                exerciseIndex = next
            }
            restAfterLastSet = .full
            return performed
        }

        let (next, rest) = Self.advance(from: position, in: steps, plan: plan, logged: loggedSides)
        if let next { exerciseIndex = next }
        restAfterLastSet = rest
        return performed
    }

    /// Jumps to an exercise the lifter picked out of order. Out-of-range is a
    /// caller bug, not a session change, so it is ignored rather than trapped.
    public mutating func select(exerciseIndex index: Int) {
        guard plan.exercises.indices.contains(index) else { return }
        exerciseIndex = index
    }

    public func completedSets(forExercise index: Int) -> Int {
        loggedSides.indices.contains(index) ? loggedSides[index].count : 0
    }

    /// The next exercise with sets still owed, searching from `start`
    /// forwards and then wrapping to the beginning — wrapping so that
    /// skipping an exercise and coming back to it later works without a
    /// separate "unfinished" screen. `nil` when the whole plan is done.
    ///
    /// Owed is measured in sets to *perform*: an each-side exercise is not
    /// done until both sides of every prescribed row are.
    private static func nextUnfinished(from start: Int, plan: WorkoutPlan,
                                       logged: [[PlanSide?]]) -> Int? {
        let count = plan.exercises.count
        guard count > 0 else { return nil }
        for offset in 0..<count {
            let index = (start + offset) % count
            guard logged.indices.contains(index) else { continue }
            if logged[index].count < plan.exercises[index].plannedSets.count { return index }
        }
        return nil
    }

    // MARK: - Rounds

    /// One place in the order a plan is trained in: one prescribed row of one
    /// exercise. An each-side row is both its sides, so a superset of an
    /// each-side lunge and a row goes left lunge, right lunge, row, rest.
    struct Step: Equatable {
        var exercise: Int
        var row: Int
        /// The first exercise of the block -- a group, or an exercise alone.
        var block: Int
        var grouped: Bool
    }

    /// Every prescribed row of the plan in the order it is trained: an
    /// ungrouped exercise is its rows in order; a group is one row of each
    /// member, in order, then the next round, and a member that has run out
    /// is skipped. LIFT for iPhone's `SessionRest.order`, over prescribed
    /// rows rather than logged sets, because the watch counts against the
    /// plan before anything is logged.
    static func order(_ plan: WorkoutPlan) -> [Step] {
        let exercises = plan.exercises
        let groups = PlanGrouping.runs(exercises.map(\.group))
        var steps: [Step] = []
        var i = 0
        while i < exercises.count {
            guard let group = groups[i] else {
                for row in exercises[i].sets.indices {
                    steps.append(Step(exercise: i, row: row, block: i, grouped: false))
                }
                i += 1
                continue
            }
            var end = i
            while end < exercises.count, groups[end] == group { end += 1 }
            let rounds = exercises[i..<end].map(\.sets.count).max() ?? 0
            for round in 0..<rounds {
                for member in i..<end where round < exercises[member].sets.count {
                    steps.append(Step(exercise: member, row: round, block: i, grouped: true))
                }
            }
            i = end
        }
        return steps
    }

    /// Where the session goes after the set at `steps[position]` was logged,
    /// and what rest that starts. `SessionRest.after(ticking:)`, step for
    /// step:
    ///
    /// 1. The round is not over while another of its sets is still to do:
    ///    go there, with no rest -- "Next: Seated Cable Rows". The other side
    ///    of an each-side row comes first, then the members in order.
    /// 2. Otherwise the next set to do after this one decides: a drop set is
    ///    no rest and "Drop set next", rest-pause is 15 seconds, anything
    ///    else the full rest. Nothing after it is the full rest too.
    ///
    /// The position wraps to the first set still owed once nothing after
    /// this one is, so an exercise skipped earlier is picked up again --
    /// the rest does not, exactly as the phone's does not look backwards.
    private static func advance(from position: Int, in steps: [Step], plan: WorkoutPlan,
                                logged: [[PlanSide?]]) -> (exercise: Int?, rest: Rest) {
        func done(_ step: Step) -> Bool {
            let through = plan.exercises[step.exercise].plannedSets.filter { $0.row <= step.row }.count
            return logged[step.exercise].count >= through
        }
        let ticked = steps[position]

        if ticked.grouped {
            let waiting = steps.filter { $0.block == ticked.block && $0.row == ticked.row && !done($0) }
            if let next = waiting.first(where: { $0 == ticked }) ?? waiting.first {
                return (next.exercise, .none(cue: "Next: \(plan.exercises[next.exercise].name)"))
            }
        }

        let next = done(ticked) ? steps[(position + 1)...].first(where: { !done($0) }) : ticked
        guard let next else {
            return (steps.first(where: { !done($0) })?.exercise, .full)
        }
        let kind = nextPlanned(for: plan.exercises[next.exercise], logged: logged[next.exercise])?.kind
        switch kind {
        case .drop?:      return (next.exercise, .none(cue: "Drop set next"))
        case .restPause?: return (next.exercise, .short(seconds: restPauseSeconds))
        case nil:         return (next.exercise, .full)
        }
    }

    /// LIFT for iPhone's rule, function for function: walk the prescribed
    /// sided sets in the order the coach wrote them and stop at the first one
    /// the log has not filled on that side; when every one is filled, offer
    /// whichever side has fewer logged, left breaking a tie.
    private static func side(for exercise: PlanExercise, logged: [PlanSide?]) -> PlanSide? {
        let order = exercise.plannedSets.compactMap(\.side)
        guard !order.isEmpty else { return nil }

        var have: [PlanSide: Int] = [:]
        for side in logged.compactMap({ $0 }) { have[side, default: 0] += 1 }

        var used: [PlanSide: Int] = [:]
        for side in order {
            if used[side, default: 0] >= have[side, default: 0] { return side }
            used[side, default: 0] += 1
        }
        guard exercise.eachSide else { return nil }
        return have[.right, default: 0] < have[.left, default: 0] ? .right : .left
    }
}
