import Foundation
import LiftCore

/// The rules behind Train's year and muscle cards and Home's body weight
/// card: value types with no view in them, so `ProgressRulesTests` can pin
/// what each one says. Counting, never grading: a quiet week is a count of
/// zero, said plainly, and nothing is coloured as a failure.

// MARK: - The year

/// A year of training days as weeks of seven, oldest first, ending with the
/// week holding `today`. A day's level is from its working sets: 0 none, 1 a
/// few (1-9), 2 a session (10-19), 3 a big one (20 or more). Fixed steps rather
/// than quartiles of the year, so the same day reads the same next month.
enum TrainingYear {
    struct Day: Equatable {
        let key: String
        let date: Date
        let sets: Int
        /// After today: drawn as nothing at all, never as a rest day.
        let isFuture: Bool
        var level: Int { isFuture ? 0 : TrainingYear.level(sets) }
    }

    static func level(_ sets: Int) -> Int {
        switch sets {
        case ..<1: 0
        case 1..<10: 1
        case 10..<20: 2
        default: 3
        }
    }

    /// `setsByDay` is keyed by `DayKey`. `weeks` columns, each Monday-first or
    /// Sunday-first as the reader's calendar is.
    static func weeks(setsByDay: [String: Int], today: Date, weeks count: Int = 53,
                      calendar: Calendar = .current) -> [[Day]] {
        let start = calendar.startOfDay(for: today)
        guard let thisWeek = calendar.dateInterval(of: .weekOfYear, for: start)?.start,
              let first = calendar.date(byAdding: .weekOfYear, value: -(count - 1), to: thisWeek)
        else { return [] }
        return (0..<count).map { week in
            (0..<7).compactMap { offset in
                guard let date = calendar.date(byAdding: .day, value: week * 7 + offset, to: first)
                else { return nil }
                let key = DayKey.make(from: date)
                return Day(key: key, date: date, sets: setsByDay[key] ?? 0, isFuture: date > start)
            }
        }
    }

    /// Days with any working set in the 365 days up to and including today.
    static func trainingDays(setsByDay: [String: Int], today: Date,
                             calendar: Calendar = .current) -> Int {
        let end = calendar.startOfDay(for: today)
        guard let start = calendar.date(byAdding: .day, value: -364, to: end) else { return 0 }
        return setsByDay.filter { key, sets in
            guard sets > 0, let date = DayKey.date(from: key) else { return false }
            let day = calendar.startOfDay(for: date)
            return day >= start && day <= end
        }.count
    }
}

// MARK: - Muscles this week

/// Working sets per primary muscle over the calendar week holding `today`.
/// A muscle comes from the exercise as logged, and failing that from the
/// exercise database by name and equipment: an exercise started from a routine
/// is logged without one. An exercise nobody can place is counted as
/// unplaced, said in words, rather than guessed into a muscle.
enum MuscleWeek {
    struct Logged: Equatable {
        let name: String
        let equipment: String?
        let primaryMuscle: String?
        let workingSets: Int
    }

    struct Result: Equatable {
        /// Muscle and sets, most first, names breaking a tie.
        let trained: [(muscle: String, sets: Int)]
        /// Every muscle the database knows that got no set this week.
        let untrained: [String]
        let unplacedSets: Int

        static func == (a: Result, b: Result) -> Bool {
            a.trained.map(\.muscle) == b.trained.map(\.muscle)
                && a.trained.map(\.sets) == b.trained.map(\.sets)
                && a.untrained == b.untrained && a.unplacedSets == b.unplacedSets
        }
    }

    static func key(name: String, equipment: String?) -> String {
        ExerciseKey.make(name: name, equipment: equipment)
    }

    /// `lookup` maps `key(name:equipment:)` to a muscle, and `name|` (no
    /// equipment) as the fallback a routine exercise with no equipment needs.
    static func tally(_ logged: [Logged], lookup: [String: String], allMuscles: [String]) -> Result {
        var sets: [String: Int] = [:]
        var unplaced = 0
        for entry in logged where entry.workingSets > 0 {
            let muscle = entry.primaryMuscle.flatMap { $0.isEmpty ? nil : $0 }
                ?? lookup[key(name: entry.name, equipment: entry.equipment)]
                ?? lookup[key(name: entry.name, equipment: nil)]
            if let muscle {
                sets[muscle.lowercased(), default: 0] += entry.workingSets
            } else {
                unplaced += entry.workingSets
            }
        }
        let trained = sets.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map { (muscle: $0.key, sets: $0.value) }
        let untrained = Set(allMuscles.map { $0.lowercased() }).subtracting(sets.keys).sorted()
        return Result(trained: trained, untrained: untrained, unplacedSets: unplaced)
    }
}

// MARK: - Body weight

/// The body weight card's line: the latest weigh-in, the change over the
/// period on screen, and how far from a goal, if one is set. In the reader's
/// unit; stored as kilograms like every other weight.
enum BodyWeightTrend {
    struct Point: Equatable {
        let date: Date
        let weightKg: Double
    }

    static let goalKey = "bodyWeightGoalKg"

    /// One weigh-in a day, the last of that day; newest last.
    static func daily(_ points: [Point], calendar: Calendar = .current) -> [Point] {
        var byDay: [Date: Point] = [:]
        for point in points {
            let day = calendar.startOfDay(for: point.date)
            if let kept = byDay[day], kept.date > point.date { continue }
            byDay[day] = point
        }
        return byDay.values.sorted { $0.date < $1.date }
    }

    static func summary(_ points: [Point], goalKg: Double?, unit: WeightUnit) -> String? {
        guard let latest = points.last else { return nil }
        let show = { (kg: Double) in PlateMath.text((unit.fromKilograms(kg) * 10).rounded() / 10) }
        var parts = ["\(show(latest.weightKg)) \(unit.abbreviation)"]
        if let first = points.first, points.count > 1 {
            let change = latest.weightKg - first.weightKg
            let rounded = (unit.fromKilograms(abs(change)) * 10).rounded() / 10
            parts.append(rounded == 0 ? "no change since \(day(first.date))"
                         : "\(change > 0 ? "up" : "down") \(PlateMath.text(rounded)) since \(day(first.date))")
        }
        if let goalKg, goalKg > 0 {
            let gap = (unit.fromKilograms(abs(latest.weightKg - goalKg)) * 10).rounded() / 10
            parts.append(gap == 0 ? "at your goal" : "\(PlateMath.text(gap)) from your goal of \(show(goalKg))")
        }
        return parts.joined(separator: " · ")
    }

    private static func day(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.abbreviated))
    }
}
