import SwiftUI
import SwiftData
import LiftCore

/// The next weight for an exercise started from a routine, on today's page,
/// with why (`ProgressionRule`), and "Use" to put it in the sets not yet done.
///
/// Shown only for the lifter's own routines. A routine a coach scheduled is
/// the coach's programme: the coach sets those numbers, and a second
/// suggestion on the same set would only contradict them.
struct ProgressionHint: View {
    @Environment(\.modelContext) private var context
    @AppStorage(ProgressionRule.enabledKey) private var enabled = true
    @AppStorage(PlateSetup.key(for: .pounds)) private var poundPlates = Data()
    @AppStorage(PlateSetup.key(for: .kilograms)) private var kiloPlates = Data()

    @Bindable var exercise: ExerciseEntry
    let unit: WeightUnit
    let bar: BarKind?
    /// Logged a side at a time: two lifts under one name, so no one number.
    let perSide: Bool

    @Query private var earlier: [WorkoutDay]

    init(exercise: ExerciseEntry, unit: WeightUnit, bar: BarKind?, perSide: Bool) {
        self.exercise = exercise
        self.unit = unit
        self.bar = bar
        self.perSide = perSide
        let before = Calendar.current.startOfDay(for: exercise.day?.date ?? .now)
        var descriptor = FetchDescriptor<WorkoutDay>(
            predicate: #Predicate { $0.date < before },
            sortBy: [SortDescriptor(\.date, order: .reverse)])
        descriptor.fetchLimit = 60
        _earlier = Query(descriptor)
    }

    private var target: (reps: Int, sets: Int)? {
        guard let id = ProgressionRule.routineExerciseID(exercise) else { return nil }
        let descriptor = FetchDescriptor<RoutineExercise>(predicate: #Predicate { $0.id == id })
        guard let prescribed = try? context.fetch(descriptor).first,
              let routineID = prescribed.routine?.id else { return nil }
        let booked = FetchDescriptor<ScheduledSession>(predicate: #Predicate { $0.routineID == routineID })
        guard ((try? context.fetchCount(booked)) ?? 0) == 0 else { return nil }
        let reps = prescribed.orderedSets.compactMap(\.targetReps)
        guard let most = reps.max() else { return nil }
        return (most, reps.count)
    }

    private var next: ProgressionRule.Next? {
        guard enabled, !perSide, let day = exercise.day,
              Calendar.current.isDateInToday(day.date), let target else { return nil }
        let setup = (try? JSONDecoder().decode(PlateSetup.self,
                                               from: unit == .pounds ? poundPlates : kiloPlates))
            ?? PlateSetup.standard(for: unit)
        return ProgressionRule.next(
            target: target.reps, setCount: target.sets,
            sessions: ProgressionRule.sessions(of: exercise, in: earlier, unit: unit),
            step: ProgressionRule.step(unit: unit, bar: bar, setup: setup))
    }

    /// Working sets not ticked done whose weight is not already the one.
    private func open(for weight: Double) -> [SetEntry] {
        let kg = unit.toKilograms(weight)
        return exercise.orderedSets.filter {
            !$0.isWarmup && $0.completedAt == nil && abs($0.weightKg - kg) > 0.001
        }
    }

    var body: some View {
        if let next {
            VStack(alignment: .leading, spacing: 4) {
                Text(ProgressionRule.line(next, unit: unit))
                    .font(Theme.detail)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !open(for: next.weight).isEmpty {
                    Button("Use \(PlateMath.text(next.weight)) \(unit.abbreviation)") {
                        for set in open(for: next.weight) {
                            set.weightKg = unit.toKilograms(next.weight)
                        }
                        try? context.save()
                    }
                    .scaledFont(size: 13, weight: .semibold)
                    .foregroundStyle(Theme.accentText)
                    .frame(minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }
            }
        }
    }
}
