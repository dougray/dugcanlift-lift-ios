import SwiftUI
import SwiftData
import LiftCore

/// Shown when a coach's plan link opens. Nothing is written until the user
/// taps Accept — per the design spec, there is no partial accept in this
/// version.
struct PlanPreviewView: View {
    /// The payload and the road picks that arrived in the same link -- see
    /// `PlanLinkIntake.IncomingPlan`, which is what keeps the pair together.
    let plan: PlanLinkIntake.IncomingPlan

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var didImport = false
    @State private var importError: String?

    private var summary: PlanImportSummary { PlanImporter.summary(for: plan) }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("From \(summary.coachName)")
                        .font(.headline)
                }
                Section("This plan includes") {
                    if summary.recipeCount > 0 {
                        Label("\(summary.recipeCount) recipe\(summary.recipeCount == 1 ? "" : "s")",
                              systemImage: "fork.knife")
                    }
                    if summary.mealCount > 0 {
                        Label("\(summary.mealCount) planned meal\(summary.mealCount == 1 ? "" : "s")",
                              systemImage: "calendar")
                    }
                    if summary.workoutCount > 0 {
                        Label("\(summary.workoutCount) workout\(summary.workoutCount == 1 ? "" : "s")",
                              systemImage: "dumbbell")
                    }
                    if summary.scheduledSessionCount > 0 {
                        Label("Scheduled on \(summary.scheduledSessionCount) day\(summary.scheduledSessionCount == 1 ? "" : "s")",
                              systemImage: "clock")
                    }
                    // Named like the other halves, so a send that is only
                    // picks is not offered as a plan with nothing in it.
                    if summary.roadPickCount > 0 {
                        Label("\(summary.roadPickCount) Road Food pick\(summary.roadPickCount == 1 ? "" : "s")",
                              systemImage: "car")
                    }
                }
                if didImport {
                    Section {
                        Label("Added to your library", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        // Picks land on a screen of their own rather than in
                        // the library, so they are the one part worth saying
                        // where to find. LIFT web opens Road Food outright
                        // when a plan is only picks; a sheet over a tab is
                        // the wrong place to push someone from, so this says
                        // it in words instead.
                        if summary.roadPickCount > 0 {
                            Text("Your coach's picks are on Road Food, under Food. They sit at the "
                                 + "top of each place's list; nothing else about the ranking changes.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .readableListMargins()
            .navigationTitle("New Plan")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Decline") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(didImport ? "Done" : "Accept") {
                        if didImport {
                            dismiss()
                        } else {
                            accept()
                        }
                    }
                }
            }
            .alert("Couldn't add this plan", isPresented: .constant(importError != nil), presenting: importError) { _ in
                Button("OK") { importError = nil }
            } message: { message in
                Text(message)
            }
        }
    }

    private func accept() {
        do {
            let hash = try PlanImporter.hash(of: plan.payload, roadPickIDs: plan.roadPickIDs)
            try PlanImporter.accept(plan, hash: hash, in: context)
            didImport = true
            // A coach's plan can book a session for today; if it just did,
            // the watch should have it without the lifter opening anything.
            // No-op when the plan schedules nothing for today.
            WatchSyncReceiver.shared?.pushTodaysPlan()
        } catch {
            importError = "This plan couldn't be added. Please try again."
        }
    }
}
