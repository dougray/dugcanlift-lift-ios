import SwiftUI
import SwiftData
import WidgetKit

struct WorkoutsView: View {
    @Environment(\.modelContext) private var context

    @Query(filter: #Predicate<WorkoutSession> { $0.endedAt == nil },
           sort: \WorkoutSession.startedAt, order: .reverse)
    private var active: [WorkoutSession]

    @Query(filter: #Predicate<WorkoutSession> { $0.endedAt != nil },
           sort: \WorkoutSession.startedAt, order: .reverse)
    private var history: [WorkoutSession]

    var body: some View {
        NavigationStack {
            List {
                if let session = active.first {
                    Section("In progress") {
                        NavigationLink {
                            ActiveWorkoutView(session: session)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(session.title).font(.headline)
                                Text("\(session.exercises.count) exercises · \(session.completedSetCount) sets")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } else {
                    Section {
                        Button("Start Workout", systemImage: "play.fill") {
                            startWorkout()
                        }
                    }
                }

                if !history.isEmpty {
                    Section("History") {
                        ForEach(history) { session in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(session.title)
                                Text("\(session.dayKey) · \(Int(session.totalVolumeKg)) kg volume")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .onDelete(perform: deleteHistory)
                    }
                }
            }
            .navigationTitle("Workouts")
        }
    }

    private func startWorkout() {
        context.insert(WorkoutSession(title: "Workout"))
        try? context.save()
    }

    private func deleteHistory(_ offsets: IndexSet) {
        for index in offsets { context.delete(history[index]) }
        try? context.save()
        WidgetCenter.shared.reloadAllTimelines()
    }
}

struct ActiveWorkoutView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @Bindable var session: WorkoutSession
    @State private var showingPicker = false

    var body: some View {
        List {
            ForEach(session.orderedExercises) { exercise in
                Section {
                    ForEach(exercise.orderedSets) { set in
                        SetRow(set: set) { save() }
                    }
                    Button("Add set", systemImage: "plus") {
                        addSet(to: exercise)
                    }
                    .font(.callout)
                } header: {
                    HStack {
                        Text(exercise.name)
                        Spacer()
                        if exercise.volumeKg > 0 {
                            Text("\(Int(exercise.volumeKg)) kg")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section {
                Button("Add exercise", systemImage: "plus.circle") {
                    showingPicker = true
                }
                Button("Finish workout", systemImage: "checkmark.circle") {
                    finish()
                }
                .disabled(session.exercises.isEmpty)
            }
        }
        .navigationTitle(session.title)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingPicker) {
            ExercisePickerView { record in
                addExercise(record)
            }
        }
    }

    /// Copies name, muscle and equipment onto the entry rather than storing
    /// only the reference ID — see the snapshot rule in CLAUDE.md.
    private func addExercise(_ record: ExerciseRecord) {
        let entry = ExerciseEntry(
            exerciseRefID: record.id,
            name: record.name,
            orderIndex: session.exercises.count,
            primaryMuscle: record.primaryMuscle,
            equipment: record.equipment
        )
        entry.sets = [SetEntry(orderIndex: 0)]
        session.exercises.append(entry)
        save()
    }

    private func addSet(to exercise: ExerciseEntry) {
        let previous = exercise.orderedSets.last
        // Prefill from the previous set — the single biggest reduction in taps
        // during a workout, when people are logging between sets.
        let new = SetEntry(
            orderIndex: exercise.sets.count,
            reps: previous?.reps ?? 0,
            weightKg: previous?.weightKg ?? 0
        )
        exercise.sets.append(new)
        save()
    }

    private func finish() {
        session.endedAt = .now
        save()
        dismiss()
    }

    private func save() {
        try? context.save()
        WidgetCenter.shared.reloadAllTimelines()
    }
}

struct SetRow: View {
    @Bindable var set: SetEntry
    let onChange: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button {
                set.completedAt = set.completedAt == nil ? .now : nil
                onChange()
            } label: {
                Image(systemName: set.completedAt == nil ? "circle" : "checkmark.circle.fill")
                    .foregroundStyle(set.completedAt == nil ? Color.secondary : Color.green)
            }
            .buttonStyle(.plain)

            TextField("Reps", value: $set.reps, format: .number)
                .keyboardType(.numberPad)
                .frame(width: 55)
            Text("×").foregroundStyle(.secondary)
            TextField("kg", value: $set.weightKg, format: .number)
                .keyboardType(.decimalPad)
                .frame(width: 70)
            Text("kg").font(.caption).foregroundStyle(.secondary)

            Spacer()

            if set.isWarmup {
                Text("W")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.orange)
            }
        }
        .onSubmit(onChange)
        .swipeActions {
            Button(set.isWarmup ? "Working" : "Warmup") {
                set.isWarmup.toggle()
                onChange()
            }
            .tint(.orange)
        }
    }
}
