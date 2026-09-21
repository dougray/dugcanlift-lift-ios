import Foundation

/// Where the lifter is inside a pushed plan: which exercise, which set of it,
/// and what to do when a set is logged.
///
/// A value type with no view in it, for the reason `RestTimer` is one: this
/// decides what the Now screen says and when the next exercise starts, and a
/// rule living in a view's `@State` cannot be tested. `GuidedSessionTests`
/// pins it.
///
/// It tracks *position*, never the sets themselves. The sets logged against a
/// plan are ordinary `DraftSet`s on an ordinary `WorkoutDraft`, so nothing
/// downstream — revision, outbox, `SESSION_FINISHED` — knows a plan existed.
public struct GuidedSession: Equatable, Sendable {

    public let plan: WorkoutPlan

    /// Sets completed per exercise, parallel to `plan.exercises`.
    public private(set) var completedSets: [Int]
    public private(set) var exerciseIndex: Int

    public init(plan: WorkoutPlan) {
        self.plan = plan
        self.completedSets = Array(repeating: 0, count: plan.exercises.count)
        // An exercise prescribing no sets at all is already done, so the
        // session opens on the first one that actually asks for something.
        self.exerciseIndex = Self.nextUnfinished(
            from: 0, plan: plan, completed: Array(repeating: 0, count: plan.exercises.count)
        ) ?? 0
    }

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
    /// exercise. Clamped to the last set once the exercise is finished, so a
    /// caller reading a prescription after the final set gets the final set's.
    public var currentSetIndex: Int {
        guard let exercise = currentExercise else { return 0 }
        return min(completedSets[exerciseIndex], max(0, exercise.sets.count - 1))
    }

    /// 1-based, for "3/5".
    public var currentSetNumber: Int {
        guard let exercise = currentExercise else { return 0 }
        return min(completedSets[exerciseIndex] + 1, exercise.sets.count)
    }

    public var currentSetCount: Int { currentExercise?.sets.count ?? 0 }

    /// "3/5", the set position exactly as the design spec draws it.
    public var positionText: String {
        guard currentExercise != nil else { return "" }
        return "\(currentSetNumber)/\(currentSetCount)"
    }

    public var currentPrescription: PrescribedSet? {
        guard let exercise = currentExercise, exercise.sets.indices.contains(currentSetIndex)
        else { return nil }
        return exercise.sets[currentSetIndex]
    }

    public var isComplete: Bool {
        Self.nextUnfinished(from: 0, plan: plan, completed: completedSets) == nil
    }

    /// Sets done across the whole plan, for a progress line.
    public var completedSetCount: Int { completedSets.reduce(0, +) }

    // MARK: - Moving

    /// Records one completed set against the current exercise and advances
    /// when that exercise has had all of its, returning the prescription that
    /// was just performed — which is where the rest interval comes from.
    ///
    /// Logging more sets than were prescribed is not an error: the count
    /// keeps rising, the exercise is finished either way, and the extra set
    /// is on the draft like any other. A plan is a prescription, not a limit.
    @discardableResult
    public mutating func recordSet() -> PrescribedSet? {
        guard currentExercise != nil else { return nil }
        let performed = currentPrescription
        completedSets[exerciseIndex] += 1
        if let next = Self.nextUnfinished(from: exerciseIndex, plan: plan, completed: completedSets) {
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
        completedSets.indices.contains(index) ? completedSets[index] : 0
    }

    /// The next exercise with sets still owed, searching from `start`
    /// forwards and then wrapping to the beginning — wrapping so that
    /// skipping an exercise and coming back to it later works without a
    /// separate "unfinished" screen. `nil` when the whole plan is done.
    private static func nextUnfinished(from start: Int, plan: WorkoutPlan, completed: [Int]) -> Int? {
        let count = plan.exercises.count
        guard count > 0 else { return nil }
        for offset in 0..<count {
            let index = (start + offset) % count
            guard completed.indices.contains(index) else { continue }
            if completed[index] < plan.exercises[index].sets.count { return index }
        }
        return nil
    }
}
