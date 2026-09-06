import LiftKit
import SwiftUI

struct WorkoutView: View {
    @EnvironmentObject private var session: WorkoutSessionModel

    var body: some View {
        TabView {
            ExerciseListView()
            RestTimerView()
            SummaryView()
        }
        .tabViewStyle(.verticalPage)
    }
}

struct ExerciseListView: View {
    @EnvironmentObject private var session: WorkoutSessionModel

    var body: some View {
        List {
            if let draft = session.draft {
                ForEach(draft.exercises) { exercise in
                    NavigationLink {
                        LogSetView(exerciseID: exercise.id)
                    } label: {
                        ExerciseRow(exercise: exercise, unit: session.unit)
                    }
                }
            }
            NavigationLink("Add Exercise") { ExercisePickerView() }
        }
        .navigationTitle(session.draft?.name ?? "Workout")
    }
}

struct ExerciseRow: View {
    let exercise: DraftExercise
    let unit: WeightUnit

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(exercise.displayName)
                .font(.headline)
                .lineLimit(1)
            if let last = exercise.sets.last {
                Text(last.display(unit: unit))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text("No sets yet")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// A short, static list is the right shape for the watch: the full reference
/// database lives on the phone, and scrolling thousands of rows on a wrist is
/// not a feature.
struct ExercisePickerView: View {
    @EnvironmentObject private var session: WorkoutSessionModel
    @Environment(\.dismiss) private var dismiss

    private static let common: [(refID: String, name: String, equipment: String)] = [
        ("bench-barbell", "Bench Press", "barbell"),
        ("squat-barbell", "Squat", "barbell"),
        ("deadlift-barbell", "Deadlift", "barbell"),
        ("ohp-barbell", "Overhead Press", "barbell"),
        ("row-barbell", "Bent Over Row", "barbell"),
        ("pullup-bodyweight", "Pull Up", "bodyweight")
    ]

    var body: some View {
        List(Self.common, id: \.refID) { item in
            Button(item.name) {
                session.addExercise(refID: item.refID, name: item.name, equipment: item.equipment)
                dismiss()
            }
        }
        .navigationTitle("Exercise")
    }
}
