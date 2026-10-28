import SwiftUI
import SwiftData
import LiftCore

/// One routine's exercises and target sets, and its set types: "Superset with
/// next" on every exercise but the last, and Straight / Drop / Rest-pause on a
/// set after the first (PLAN-FORMAT.md "Set types").
///
/// The controls follow Coach web's editor and stay out of the way the same
/// way: the kind menu shows only on an exercise that already has a drop or
/// rest-pause set, or once "Drop / rest-pause" is tapped, so a routine of
/// straight sets reads as it always did. The rules are `ExerciseGrouping` and
/// `RoutineSetTypes`, not this view: joining onto a superset makes a circuit,
/// splitting keeps what is before the split grouped, a group of one is no
/// group, and an exercise's first set has no kind.
///
/// The numbers themselves are not edited here -- this build has never had a
/// routine editor for them; a routine's sets are what a coach sent, a
/// ready-made split wrote, or New Routine typed.
struct RoutineDetailView: View {
    let routine: Routine

    @AppStorage(RoutineSetTypes.storageKey) private var setTypesData = Data()
    @AppStorage(PlanSides.storageKey) private var planSidesData = Data()
    @AppStorage("weightUnit") private var unitRaw = WeightUnit.pounds.rawValue
    /// Exercises whose "Drop / rest-pause" was tapped. Not stored, as Coach
    /// web's `kindsAsked` is not: a kind once chosen keeps the menu showing.
    @State private var kindsAsked: Set<UUID> = []
    /// Read so a change of interface style re-applies the navigation bar's
    /// colours -- see `RoutinesView`, the screen this is pushed from.
    @Environment(\.colorScheme) private var colorScheme

    private var unit: WeightUnit { WeightUnit(rawValue: unitRaw) ?? .pounds }

    var body: some View {
        let setTypes = RoutineSetTypes.decode(setTypesData)
        let sides = (try? JSONDecoder().decode(PlanSides.self, from: planSidesData)) ?? PlanSides()
        let exercises = routine.orderedExercises
        let labels = setTypes.labels(exercises)

        List {
            ForEach(Array(exercises.enumerated()), id: \.element.id) { index, exercise in
                Section {
                    exerciseRows(exercise, index: index, of: exercises,
                                 setTypes: setTypes, sides: sides)
                } header: {
                    VStack(alignment: .leading, spacing: 2) {
                        // "Superset A · A1" on a grouped exercise; nothing on
                        // any other.
                        if let label = labels[index] {
                            Text(label.text)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Theme.accentText)
                        }
                        Text(title(exercise))
                            .font(.headline)
                            .foregroundStyle(Theme.textPrimary)
                            .textCase(nil)
                        if sides.isEachSide(exercise) {
                            Text("Each side")
                                .font(.caption)
                                .textCase(nil)
                        }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .readableListMargins()
        .background(Theme.background)
        .navigationTitle(routine.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(colorScheme, for: .navigationBar)
        .overlay {
            if exercises.isEmpty {
                ContentUnavailableView("No Exercises", systemImage: "list.bullet",
                                       description: Text("This routine has no exercises yet."))
            }
        }
    }

    @ViewBuilder
    private func exerciseRows(_ exercise: RoutineExercise, index: Int, of exercises: [RoutineExercise],
                              setTypes: RoutineSetTypes, sides: PlanSides) -> some View {
        let sets = exercise.orderedSets
        let kinds = setTypes.kinds(of: exercise)
        let showsKinds = setTypes.showsKinds(exercise) || kindsAsked.contains(exercise.id)

        if sets.isEmpty {
            Text("No target sets")
                .foregroundStyle(Theme.textSecondary)
        }
        ForEach(Array(sets.enumerated()), id: \.element.id) { setIndex, set in
            HStack(spacing: 10) {
                Text("\(setIndex + 1).")
                    .monospacedDigit()
                    .foregroundStyle(Theme.textSecondary)
                    .accessibilityHidden(true)
                Text(setText(set, side: sides.side(of: set)))
                    .foregroundStyle(Theme.textPrimary)
                Spacer(minLength: 0)
                // The first set has no menu: there is no set before it to drop
                // from or pause after.
                if showsKinds && setIndex > 0 {
                    kindMenu(set, in: exercise, kind: kinds[setIndex], number: setIndex + 1)
                }
            }
            .accessibilityElement(children: .combine)
        }

        // The last exercise has no next to join.
        // A checkbox button, as Train's "Log left and right separately" is,
        // rather than a `Toggle`: the same control for the same kind of
        // choice, and the shape Coach web's chip has.
        if index + 1 < exercises.count {
            let joined = setTypes.groupedWithNext(exercises, at: index)
            Button {
                var updated = RoutineSetTypes.decode(setTypesData)
                updated.setGroupedWithNext(!joined, at: index, in: exercises)
                store(updated)
            } label: {
                Label("Superset with next", systemImage: joined ? "checkmark.square.fill" : "square")
                    .foregroundStyle(joined ? Theme.accentText : Theme.textSecondary)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Superset with next")
            .accessibilityValue(joined ? "On" : "Off")
            .accessibilityAddTraits(.isToggle)
            .accessibilityHint(joined
                               ? "Done round by round with the next exercise, then the rest"
                               : "Do this and the next exercise back to back, then rest")
        }

        // Only from a second set: the first can never be a drop or rest-pause.
        if !showsKinds && sets.count > 1 {
            Button("Drop / rest-pause") { kindsAsked.insert(exercise.id) }
                .foregroundStyle(Theme.accentText)
                .accessibilityHint("Mark a set as a drop set or rest-pause")
        }
    }

    private func kindMenu(_ set: RoutinePrescribedSet, in exercise: RoutineExercise,
                          kind: SetKind?, number: Int) -> some View {
        Picker("Type of set \(number)", selection: Binding(
            get: { kind },
            set: { chosen in
                var updated = RoutineSetTypes.decode(setTypesData)
                updated.setKind(chosen, for: set, in: exercise)
                store(updated)
            })) {
            Text("Straight").tag(SetKind?.none)
            ForEach(SetKind.allCases) { choice in
                Text(choice.displayName).tag(SetKind?.some(choice))
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .tint(Theme.accentText)
    }

    private func store(_ setTypes: RoutineSetTypes) {
        if let data = setTypes.encoded() { setTypesData = data }
    }

    private func title(_ exercise: RoutineExercise) -> String {
        exercise.equipment.isEmpty ? exercise.name : "\(exercise.name) (\(exercise.equipment.capitalized))"
    }

    /// The set as the coach's week card spells it, then its side: "30 x 12 L".
    private func setText(_ set: RoutinePrescribedSet, side: SetSide?) -> String {
        let text = PlanAndLog.setText(
            PlanAndLog.SetValues(weightKg: set.targetWeightKg, reps: set.targetReps,
                                 rpe: set.targetRPE, durationSec: set.targetDurationSec,
                                 distanceMeters: set.targetDistanceMeters),
            unit: unit)
        return side.map { "\(text) \($0.shortLabel)" } ?? text
    }
}
