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
public struct GuidedSession: Equatable, Sendable {

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
    public var positionText: String {
        guard currentExercise != nil else { return "" }
        let position = "\(currentSetNumber)/\(currentSetCount)"
        guard let side = currentSide else { return position }
        return "\(position) · \(side.shortLabel)"
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
        let planned = exercise.plannedSets
        guard let side = currentSide else {
            guard planned.indices.contains(currentSetIndex) else { return nil }
            return planned[currentSetIndex].prescription
        }
        let onSide = planned.filter { $0.side == side }
        let done = loggedSides[exerciseIndex].filter { $0 == side }.count
        if onSide.indices.contains(done) { return onSide[done].prescription }
        // Past what the coach asked for on this side: the last thing they did
        // ask for there, which is what the lifter is repeating.
        return onSide.last?.prescription ?? planned.last?.prescription
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
    @discardableResult
    public mutating func recordSet(on side: PlanSide? = nil) -> PrescribedSet? {
        guard currentExercise != nil else { return nil }
        let performed = currentPrescription
        loggedSides[exerciseIndex].append(side)
        if let next = Self.nextUnfinished(from: exerciseIndex, plan: plan, logged: loggedSides) {
            exerciseIndex = next
        }
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
