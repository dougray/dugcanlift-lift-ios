import SwiftUI
import SwiftData
import LiftCore

/// Shown when a coach's plan link opens. Nothing is written until the user
/// taps Accept — per the design spec, there is no partial accept in this
/// version.
struct PlanPreviewView: View {
    let payload: PlanPayload

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var didImport = false
    @State private var importError: String?

    private var summary: PlanImportSummary { PlanImporter.summary(for: payload) }

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
                }
                if didImport {
                    Section {
                        Label("Added to your library", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
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
            let hash = try PlanImporter.hash(of: payload)
            try PlanImporter.accept(payload, hash: hash, in: context)
            didImport = true
        } catch {
            importError = "This plan couldn't be added. Please try again."
        }
    }
}
