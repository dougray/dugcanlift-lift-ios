import Foundation

/// Which top-level screen the watch app shows.
///
/// Pulled out of `RootView` so the rule is tested rather than remembered: a
/// finished workout is over, and must never keep the lifter on the workout
/// pager. That once happened -- `finishWorkout()` marked the draft finished
/// but left it in place, and `RootView` only checked for `nil`, so the start
/// screen (Start Workout, Start Run, Log Food, Export) was unreachable until
/// the app process died. `finishWorkout()` now clears the draft as well; this
/// rule means the screen no longer depends on that alone.
public enum WatchRoute: Equatable, Sendable {
    /// An outdoor run or hike is being recorded.
    case outdoorActivity
    /// A lifting workout is in progress.
    case workout
    /// Nothing is in progress: start a workout, a run, or log food.
    case start

    public static func resolve(draft: WorkoutDraft?, isRecordingOutdoor: Bool) -> WatchRoute {
        // An in-progress outdoor recording owns the screen first.
        if isRecordingOutdoor { return .outdoorActivity }
        guard let draft, !draft.isFinished else { return .start }
        return .workout
    }
}
