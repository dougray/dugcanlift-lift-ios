import LiftKit
import SwiftUI

/// Digital Crown entry rather than a keyboard — the user is holding a bar.
struct LogSetView: View {
    let exerciseID: UUID

    @EnvironmentObject private var session: WorkoutSessionModel
    @Environment(\.dismiss) private var dismiss

    @State private var weight: Double = 135
    @State private var reps: Int = 5
    @State private var rpe: Double = 8

    private var exercise: DraftExercise? { session.draft?.exercise(exerciseID) }

    var body: some View {
        List {
            if let previous = exercise?.sets.last {
                Section("Previous") {
                    Text(previous.display(unit: session.unit))
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Stepper(value: $weight, in: 0...1500, step: 5) {
                    LabeledValue("Weight", "\(Int(weight)) \(session.unit.abbreviation)")
                }
                .focusable()
                .digitalCrownRotation($weight, from: 0, through: 1500, by: 5)

                Stepper(value: $reps, in: 1...50) {
                    LabeledValue("Reps", "\(reps)")
                }

                Stepper(value: $rpe, in: 6...10, step: 0.5) {
                    LabeledValue("RPE", rpe == rpe.rounded()
                                 ? String(Int(rpe))
                                 : String(format: "%.1f", rpe))
                }
            }

            Section {
                Button("Log Set") {
                    session.logSet(to: exerciseID, weight: weight, reps: reps, rpe: rpe)
                    dismiss()
                }
            }
        }
        .navigationTitle(exercise?.name ?? "Set")
        .onAppear(perform: seedFromPreviousSet)
    }

    /// Most sets repeat the last one, so start there instead of at a default.
    private func seedFromPreviousSet() {
        guard let previous = exercise?.sets.last else { return }
        weight = (session.unit.fromKilograms(previous.weightKg) / 5).rounded() * 5
        reps = previous.reps
        if let previousRPE = previous.rpe { rpe = previousRPE }
    }
}

struct LabeledValue: View {
    let label: String
    let value: String

    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3)
        }
    }
}
