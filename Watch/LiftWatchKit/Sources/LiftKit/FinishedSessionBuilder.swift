import Foundation
import LiftSync

// Turning the watch's own draft into the `session` payload that travels home
// on `SESSION_FINISHED`. In LiftKit rather than beside the wire types in
// LiftSync because it reads `WorkoutDraft`, the watch's domain, which the
// phone does not compile; and out of `WorkoutSessionModel` because this is
// the rule that decides whether a lifter's work reaches their phone intact,
// and a rule in a view model's method body is a rule nobody can test
// without a `WCSession`.

extension WorkoutDraft {

    /// This workout as the phone will store it.
    ///
    /// Everything the draft holds travels: every exercise in order, every set
    /// with its weight, reps, RPE, warmup flag and **side**, and when it was
    /// completed. Nothing is filtered — an incomplete set (entered, never
    /// completed) is still a set somebody typed, and dropping it here would
    /// be the watch deciding on its own that part of a session did not
    /// happen.
    ///
    /// `performedOn` is the local day the session **started**: a set logged
    /// at 00:10 belongs to the evening it began, which is how the phone's own
    /// day-of-record works, and taking it from `finishedAt` would file a late
    /// session under tomorrow.
    ///
    /// `name` falls back to "Workout" only when the draft has none at all —
    /// the phone names a blank day from this, and an empty name would leave
    /// the day unnamed rather than wrong.
    public func finishedSession(calendar: Calendar = .current) -> FinishedSession {
        FinishedSession(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Workout" : name,
            focus: focus.rawValue,
            performedOn: WireDay.key(for: startedAt, calendar: calendar),
            startedAt: startedAt,
            finishedAt: finishedAt ?? updatedAt,
            exercises: exercises
                .sorted { $0.orderIndex < $1.orderIndex }
                .map { exercise in
                    PerformedExercise(
                        name: exercise.name,
                        // "" is not an equipment: the key is omitted, so the
                        // receiver matches this lift's identity the same way
                        // it matches one of its own.
                        equipment: (exercise.equipment?.isEmpty ?? true) ? nil : exercise.equipment,
                        sets: exercise.sets
                            .sorted { $0.orderIndex < $1.orderIndex }
                            .map { set in
                                PerformedSet(
                                    weightKg: set.weightKg,
                                    reps: set.reps,
                                    rpe: set.rpe,
                                    isWarmup: set.isWarmup,
                                    side: set.side,
                                    completedAt: set.completedAt
                                )
                            }
                    )
                }
        )
    }
}
