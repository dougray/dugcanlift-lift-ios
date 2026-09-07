import SwiftUI
import SwiftData

/// List, create, and start routines. Grouped by folder the way Android's
/// Routines screen is; "" is the default/ungrouped folder.
struct RoutinesView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Routine.createdAt, order: .reverse) private var routines: [Routine]
    @State private var isCreatingRoutine = false

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
                        .onDelete { offsets in
                            for index in offsets { context.delete(group.routines[index]) }
                            try? context.save()
                        }
                    }
                }
            }
            .navigationTitle("Routines")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("New", systemImage: "plus") { isCreatingRoutine = true }
                }
            }
            .sheet(isPresented: $isCreatingRoutine) {
                NewRoutineView()
            }
            .overlay {
                if routines.isEmpty {
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

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(routine.name).font(.headline)
            Text("\(routine.orderedExercises.count) exercise\(routine.orderedExercises.count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Start Today") {
                routine.startSession(on: .now, in: context)
            }
            .font(.caption.weight(.semibold))
            .buttonStyle(.borderless)
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
