import LiftKit
import SwiftUI

struct SummaryView: View {
    @EnvironmentObject private var session: WorkoutSessionModel
    @State private var confirmingFinish = false

    var body: some View {
        List {
            if let draft = session.draft {
                Section {
                    LabeledValue("Sets", "\(draft.completedSetCount) of \(draft.totalSetCount)")
                    LabeledValue(
                        "Volume",
                        "\(Int(session.unit.fromKilograms(draft.totalVolumeKg).rounded())) \(session.unit.abbreviation)"
                    )
                }
            }

            Section("Sync") {
                Label(
                    session.isPhoneReachable ? "Phone connected" : "Offline — queued",
                    systemImage: session.isPhoneReachable ? "iphone.radiowaves.left.and.right" : "iphone.slash"
                )
                .font(.caption)
                if !session.outbox.isEmpty {
                    Text("\(session.outbox.pending.count) pending")
                        .font(.caption2)
                        .foregroundStyle(DclTheme.muted)
                }
            }

            Section {
                // Ends the HealthKit session and sends the workout: asks
                // first, since a stray tap mid-session can't be taken back.
                Button("Finish Workout", role: .destructive) {
                    confirmingFinish = true
                }
            }
        }
        .navigationTitle("Summary")
        .confirmationDialog("Finish this workout?", isPresented: $confirmingFinish,
                            titleVisibility: .visible) {
            Button("Finish Workout", role: .destructive) { session.finishWorkout() }
            Button("Keep Training", role: .cancel) {}
        }
    }
}
