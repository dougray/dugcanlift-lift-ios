import Foundation
import LiftCore

/// What to lift next time, from what was lifted last time: double
/// progression, the rule most programmes write down.
///
/// - Every working set at last session's top weight reached the routine's
///   reps, and there were as many of them as the routine asks for: **up** one
///   step.
/// - Short, but not twice running at that weight: **the same weight again**.
/// - Short at the same weight two sessions running: **back off** about 10%,
///   rounded down to a step, and build up again.
///
/// It says why, every time, in the line it gives. It is a suggestion shown
/// beside the sets, never written into them unless "Use" is tapped, and it
/// only touches sets not ticked done.
///
/// No suggestion at all where there is nothing honest to say: no rep target,
/// no earlier session of this lift, or no weight (a bodyweight lift has no
/// step to take). A routine a coach scheduled gets none either, because the
/// coach programmes those numbers and a second voice on the same set is a
/// contradiction, not help (see `ProgressionHint`).
///
/// Numbers are in the unit the lifter reads, so a step is a real plate pair:
/// 185 lb goes to 190, never to 189.6.
enum ProgressionRule {
    /// One working set as it was logged.
    struct LoggedSet: Equatable {
        var weight: Double
        var reps: Int
    }

    /// One earlier day of this lift: its working sets, newest day first.
    struct Session: Equatable {
        var date: Date
        var sets: [LoggedSet]
    }

    enum Next: Equatable {
        case up(to: Double, from: Double, reps: Int, date: Date)
        case same(Double, reps: [Int], target: Int, date: Date)
        case backOff(to: Double, from: Double, target: Int)

        var weight: Double {
            switch self {
            case let .up(to, _, _, _): to
            case let .same(weight, _, _, _): weight
            case let .backOff(to, _, _): to
            }
        }
    }

    /// `target` is the routine's reps, `setCount` how many sets it asks for,
    /// `step` the smallest change of load in the lifter's unit.
    static func next(target: Int, setCount: Int, sessions: [Session], step: Double) -> Next? {
        guard target > 0, step > 0,
              let last = sessions.first, let top = topWeight(last), top > 0 else { return nil }
        let atTop = last.sets.filter { $0.weight == top }

        if atTop.count >= max(setCount, 1), atTop.allSatisfy({ $0.reps >= target }) {
            return .up(to: rounded(top + step, to: step), from: top, reps: target, date: last.date)
        }
        if sessions.count > 1, topWeight(sessions[1]) == top,
           !sessions[1].sets.filter({ $0.weight == top }).allSatisfy({ $0.reps >= target }) {
            let lighter = (top * 0.9 / step).rounded(.down) * step
            if lighter > 0, lighter < top {
                return .backOff(to: rounded(lighter, to: step), from: top, target: target)
            }
        }
        return .same(top, reps: atTop.map(\.reps), target: target, date: last.date)
    }

    private static func topWeight(_ session: Session) -> Double? {
        session.sets.map(\.weight).max()
    }

    /// A pound weight stored as kilograms comes back as 184.99999.
    static func rounded(_ value: Double, to step: Double) -> Double {
        let hundredths = (value * 100).rounded() / 100
        let steps = (hundredths / step).rounded()
        return abs(steps * step - hundredths) < 0.01 ? steps * step : hundredths
    }

    /// Two of the smallest plate owned for a bar, which is what loading one
    /// more of them a side adds; otherwise the usual dumbbell and machine
    /// jump.
    static func step(unit: WeightUnit, bar: BarKind?, setup: PlateSetup) -> Double {
        if bar != nil,
           let smallest = setup.plates.filter({ $0.pairs > 0 && $0.weight > 0 }).map(\.weight).min() {
            return smallest * 2
        }
        return unit == .pounds ? 5 : 2.5
    }

    // MARK: - Words

    static func line(_ next: Next, unit: WeightUnit) -> String {
        let u = unit.abbreviation
        switch next {
        case let .up(to, from, reps, date):
            return "Next: \(PlateMath.text(to)) \(u). Every set reached \(reps) at \(PlateMath.text(from)) last time (\(day(date)))."
        case let .same(weight, reps, target, date):
            let done = reps.map(String.init).joined(separator: ", ")
            return "Next: \(PlateMath.text(weight)) \(u) again. \(done) at \(PlateMath.text(weight)) last time (\(day(date))), aiming for \(target)."
        case let .backOff(to, from, target):
            return "Next: \(PlateMath.text(to)) \(u). Short of \(target) at \(PlateMath.text(from)) two sessions running, so back off and build up again."
        }
    }

    private static func day(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }
}

// MARK: - From the store

extension ProgressionRule {
    static let enabledKey = "suggestsNextWeight"

    /// The routine exercise a logged exercise was started from, by the
    /// `routine:<exercise id>` ref `Routine.startSession` writes.
    static func routineExerciseID(_ exercise: ExerciseEntry) -> UUID? {
        guard exercise.exerciseRefID.hasPrefix("routine:") else { return nil }
        return UUID(uuidString: String(exercise.exerciseRefID.dropFirst("routine:".count)))
    }

    /// The working sets of this lift on each earlier day, newest first. A
    /// day this lift was logged a side at a time is left out: its sides are
    /// two lifts, and one number for both would be wrong for each.
    static func sessions(of exercise: ExerciseEntry, in days: [WorkoutDay],
                         unit: WeightUnit) -> [Session] {
        let key = ExerciseKey.make(name: exercise.name, equipment: exercise.equipment)
        return days.compactMap { day in
            let entries = day.exercises.filter {
                $0.id != exercise.id && ExerciseKey.make(name: $0.name, equipment: $0.equipment) == key
            }
            let sets = entries.flatMap(\.orderedSets)
            guard !sets.contains(where: { $0.side != nil }) else { return nil }
            let working = sets
                .filter { !$0.isWarmup && $0.weightKg > 0 && $0.reps > 0 }
                .map { LoggedSet(weight: rounded(unit.fromKilograms($0.weightKg), to: 0.25), reps: $0.reps) }
            return working.isEmpty ? nil : Session(date: day.date, sets: working)
        }
    }
}
