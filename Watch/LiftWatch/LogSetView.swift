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
    private var prescription: PrescribedSet? { session.prescription(for: exerciseID) }

    var body: some View {
        List {
            if let prescription {
                Section("Prescribed") {
                    Text(prescription.summary(unit: session.unit))
                        .foregroundStyle(DclTheme.muted)
                }
            }

            if let previous = exercise?.sets.last {
                Section("Previous") {
                    Text(previous.display(unit: session.unit))
                        .foregroundStyle(DclTheme.muted)
                }
            }

            Section {
                Stepper(value: $weight, in: 0...1500, step: 5) {
                    // Formatted rather than `Int(weight)`: a prescription of
                    // 82.5 kg seeds this field exactly, and truncating it to
                    // "82" would show a number nobody prescribed and nobody
                    // is about to lift.
                    LabeledValue("Weight", "\(Self.weightText(weight)) \(session.unit.abbreviation)")
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
        .onAppear(perform: seed)
    }

    /// What the fields start at.
    ///
    /// The prescription wins, field by field, because it is what the lifter
    /// is meant to do — and only field by field, because every one of them is
    /// optional: `[null, 5]` is five reps at a weight you pick, so the reps
    /// come from the plan and the weight from what was actually lifted. A
    /// prescribed weight seeds the field **exactly**, not rounded to the
    /// nearest five as a repeat of the last set is: one turn of the Crown to
    /// correct beats a field that disagrees with the Now screen.
    ///
    /// With no plan this is the flow that has always been here — repeat the
    /// last set of this exercise, or the 135/5/8 defaults for the first one.
    private func seed() {
        seedFromPreviousSet()

        guard let prescription else { return }
        let isFirstSetOfTheExercise = exercise?.sets.last == nil
        let last = session.lastPerformed(for: exerciseID)

        if let prescribed = prescription.weightKg {
            weight = session.unit.fromKilograms(prescribed)
        } else if isFirstSetOfTheExercise, let lastWeight = last?.weightKg {
            weight = (session.unit.fromKilograms(lastWeight) / 5).rounded() * 5
        }

        if let prescribedReps = prescription.reps {
            reps = prescribedReps
        } else if isFirstSetOfTheExercise, let lastReps = last?.reps {
            reps = lastReps
        }

        if let prescribedRPE = prescription.rpe {
            rpe = prescribedRPE
        } else if isFirstSetOfTheExercise, let lastRPE = last?.rpe {
            rpe = lastRPE
        }
    }

    /// Most sets repeat the last one, so start there instead of at a default.
    private func seedFromPreviousSet() {
        guard let previous = exercise?.sets.last else { return }
        weight = (session.unit.fromKilograms(previous.weightKg) / 5).rounded() * 5
        reps = previous.reps
        if let previousRPE = previous.rpe { rpe = previousRPE }
    }

    /// Whole numbers stay whole; a real half unit keeps its decimal.
    static func weightText(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        return rounded == rounded.rounded()
            ? String(Int(rounded))
            : String(format: "%.1f", rounded)
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
                .foregroundStyle(DclTheme.muted)
            Text(value)
                .font(.title3)
        }
    }
}
