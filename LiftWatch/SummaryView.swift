import LiftKit
import SwiftUI

struct SummaryView: View {
    @EnvironmentObject private var session: WorkoutSessionModel

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
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Button("Finish Workout", role: .destructive) {
                    session.finishWorkout()
                }
            }
        }
        .navigationTitle("Summary")
    }
}
