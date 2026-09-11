import LiftKit
import SwiftUI

/// Shows the retained log as a sequence of QR codes for the LIFT PWA to scan.
///
/// Clearing is a deliberate, confirmed tap. There is no channel back from the
/// PWA — the watch cannot know a scan succeeded — so an automatic
/// clear-on-display would lose the log whenever a scan failed or the user
/// backed out. Same model as `SHARE-FORMAT`'s send side, where the sender
/// never learns whether the coach opened the link either.
struct ExportFoodsView: View {
    @EnvironmentObject private var session: WorkoutSessionModel
    @Environment(\.dismiss) private var dismiss

    @State private var codes: [String] = []
    @State private var index = 0
    @State private var confirmingClear = false

    var body: some View {
        Group {
            if codes.isEmpty {
                Text(emptyStateMessage)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding()
            } else {
                TabView(selection: $index) {
                    ForEach(Array(codes.enumerated()), id: \.offset) { position, code in
                        VStack(spacing: 4) {
                            if let image = QRCodeImage.make(from: code) {
                                Image(uiImage: image)
                                    .interpolation(.none)
                                    .resizable()
                                    .scaledToFit()
                            }
                            if codes.count > 1 {
                                Text("\(position + 1) of \(codes.count)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .tag(position)
                    }

                    // A final page rather than a button over the code: a tap
                    // target on the same screen as the QR risks clearing the
                    // log while the user is still trying to get it scanned.
                    VStack(spacing: 8) {
                        Text(codes.count > 1
                             ? "Scan all \(codes.count) codes, then:"
                             : "Scanned it?")
                            .font(.caption2)
                            .multilineTextAlignment(.center)
                        Button("Done — clear log", role: .destructive) {
                            confirmingClear = true
                        }
                    }
                    .tag(codes.count)
                }
                .tabViewStyle(.verticalPage)
            }
        }
        .navigationTitle("Export")
        .onAppear { codes = StandaloneExport.codes(for: session.foodLog.entries) }
        .confirmationDialog("Clear the log?", isPresented: $confirmingClear) {
            Button("Clear", role: .destructive) {
                session.foodLog.clear()
                dismiss()
            }
            Button("Keep", role: .cancel) {}
        } message: {
            Text("Only do this once the codes have been scanned. This cannot be undone.")
        }
    }

    /// "Nothing logged" and "nothing exportable" are different states: a
    /// paired user can log foods every one of which lacks macros today
    /// (LIFT iOS doesn't populate `nutritionPer100g` yet), and telling them
    /// their log is empty would contradict what they just did.
    private var emptyStateMessage: String {
        let skipped = session.foodLog.skippedCount
        guard skipped > 0 else { return "Nothing logged yet." }
        let entryWord = skipped == 1 ? "entry" : "entries"
        return "\(skipped) \(entryWord) can't be exported yet. Update LIFT on your iPhone."
    }
}
