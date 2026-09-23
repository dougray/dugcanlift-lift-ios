import SwiftUI
import SwiftData
import LiftCore

/// List, create, and start routines. Grouped by folder the way Android's
/// Routines screen is; "" is the default/ungrouped folder.
struct RoutinesView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Routine.createdAt, order: .reverse) private var routines: [Routine]
    @State private var isCreatingRoutine = false

    /// Starter routines off a bundled file, for someone who hasn't written any.
    private let starters = StarterSplits.bundled()

    private var unclaimedStarters: [StarterSplit] {
        starters.filter { !StarterSplits.isAlreadySaved($0, in: routines) }
    }

    private var groupedByFolder: [(folder: String, routines: [Routine])] {
        Dictionary(grouping: routines, by: \.folder)
            .sorted { $0.key < $1.key }
            .map { (folder: $0.key.isEmpty ? "Routines" : $0.key, routines: $0.value) }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(groupedByFolder, id: \.folder) { group in
                    Section(group.folder) {
                        ForEach(group.routines) { routine in
                            RoutineRow(routine: routine)
                        }
                    }
                }

                if !unclaimedStarters.isEmpty {
                    Section {
                        ForEach(unclaimedStarters) { split in
                            StarterSplitRow(split: split) {
                                StarterSplits.insert(split, into: context)
                            }
                        }
                    } header: {
                        Text("Ready-made")
                    } footer: {
                        Text(routines.isEmpty
                             ? "Splits to start from, until you have written your own."
                             : "Splits you have not added yet.")
                    }
                }
            }
            // The app's own background rather than the system's black, and an
            // inline title: a large title here sat hard against the screen edge
            // under the app's top tabs, which no other tab does.
            .scrollContentBackground(.hidden)
            // A readable column on a wide screen, rather than rows whose
            // Start button sits a whole iPad away from their name.
            .readableListMargins()
            .background(Theme.background)
            .navigationTitle("Routines")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("New", systemImage: "plus") { isCreatingRoutine = true }
                }
            }
            .sheet(isPresented: $isCreatingRoutine) {
                NewRoutineView()
            }
            .overlay {
                // Only when there is genuinely nothing to look at. With
                // starters on screen the list is not empty, and an overlay
                // saying otherwise would cover them.
                if routines.isEmpty && unclaimedStarters.isEmpty {
                    ContentUnavailableView(
                        "No Routines Yet",
                        systemImage: "list.bullet.rectangle",
                        description: Text("Save a workout as a routine, or accept one from your coach.")
                    )
                }
            }
        }
    }
}

private struct RoutineRow: View {
    @Environment(\.modelContext) private var context
    let routine: Routine
    @State private var didSendToWatch = false
    @State private var confirmingDelete = false
    @State private var summary = RoutineRemoval.Summary()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(routine.name).font(.headline)
            Text("\(routine.orderedExercises.count) exercise\(routine.orderedExercises.count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 16) {
                Button("Start Today") {
                    routine.startSession(on: .now, in: context)
                }
                .font(.caption.weight(.semibold))
                .buttonStyle(.borderless)

                // Pins this routine as today's plan and pushes it. The push
                // is queued by the OS when the watch is out of range, so
                // this works with the watch on a charger in another room —
                // which is why the label does not promise it arrived.
                Button(didSendToWatch ? "Sent to Watch" : "Send to Watch") {
                    WatchPlanPin.save(routineID: routine.id)
                    WatchSyncReceiver.shared?.pushTodaysPlan()
                    didSendToWatch = true
                }
                .font(.caption.weight(.semibold))
                .buttonStyle(.borderless)
                .disabled(didSendToWatch)

                // A button in the row, not `.onDelete`, and that was
                // measured: the shell is a paged `TabView` (`RootView`),
                // which takes every horizontal drag for itself — a swipe on
                // Home turns to Food, and on Routines, the last page, it does
                // nothing at all. The `.onDelete` that used to be here could
                // therefore never be opened on any screen, which is why a
                // routine could not be deleted. Asking first is what makes a
                // plain button safe here, and it says what goes with it.
                Button("Delete", role: .destructive) {
                    summary = RoutineRemoval.summary(for: routine, in: context)
                    confirmingDelete = true
                }
                .font(.caption.weight(.semibold))
                .buttonStyle(.borderless)
                .tint(Theme.accent)
            }
        }
        .alert("Delete \u{201C}\(routine.name)\u{201D}?", isPresented: $confirmingDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                RoutineRemoval.remove(routine, in: context)
            }
        } message: {
            Text(RoutineRemoval.warning(summary))
        }
    }
}

/// Minimal manual creation: name + one exercise with a target weight/reps.
/// Full multi-exercise editing is a natural follow-up, not required for this
/// plan's goal (receiving coach-sent routines works without it).
private struct NewRoutineView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var exerciseName = ""
    @State private var targetWeight = ""
    @State private var targetReps = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("Routine name", text: $name)
                Section("First exercise") {
                    TextField("Exercise name", text: $exerciseName)
                    TextField("Target weight (lb)", text: $targetWeight)
                        .keyboardType(.decimalPad)
                    TextField("Target reps", text: $targetReps)
                        .keyboardType(.numberPad)
                }
            }
            .readableListMargins()
            .navigationTitle("New Routine")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func save() {
        let routine = Routine(name: name)
        if !exerciseName.isEmpty {
            let exercise = RoutineExercise(name: exerciseName, orderIndex: 0)
            let weightLb = Double(targetWeight)
            let reps = Int(targetReps)
            if weightLb != nil || reps != nil {
                exercise.prescribedSets = [RoutinePrescribedSet(
                    orderIndex: 0,
                    targetWeightKg: weightLb.map { WeightUnit.pounds.toKilograms($0) },
                    targetReps: reps
                )]
            }
            routine.exercises = [exercise]
        }
        context.insert(routine)
        try? context.save()
        dismiss()
    }
}

/// A ready-made split, before it is yours.
///
/// Deliberately not a `RoutineRow`: there is no Start and no swipe-to-delete,
/// because neither means anything yet. Adding copies it into the store, where
/// the real row takes over — so there is exactly one place that starts a
/// workout and one that deletes one.
private struct StarterSplitRow: View {
    let split: StarterSplit
    let onAdd: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(split.name).font(.headline)
            Text("\(split.exercises.count) exercises · \(split.setCount) sets")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(split.preview)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Button("Add to my routines", action: onAdd)
                .font(.caption.weight(.semibold))
                .buttonStyle(.borderless)
        }
    }
}
