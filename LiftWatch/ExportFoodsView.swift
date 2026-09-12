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
    // Captured alongside `codes` in `onAppear`: `clear()` used to wipe the
    // whole log even though only these were shown and scanned. Nothing can
    // append while this screen is up today, so that was latent rather than
    // live -- but it was true only by accident of the navigation graph, in a
    // screen whose whole purpose is not losing data. Removing exactly this
    // set (via `StandaloneFoodLog.remove(_:)`) keeps the guarantee true even
    // if that accident stops holding.
    @State private var capturedEntries: [LoggedFood] = []
    // Computed once, alongside `codes`, in `onAppear` -- not inside the
    // `ForEach` page body. `QRCodeImage.make` was being called there, and
    // `index`/`confirmingClear` are `@State` on this view, so every swipe
    // was re-encoding every materialised page (measured: 25 codes cost
    // 49.7 ms and 18.7 MB of bitmaps on a Mac; a watch is slower still).
    // One entry per `codes` index, `nil` only in the practically-unreachable
    // case `QRCodeImage.make` fails for that page.
    @State private var images: [UIImage?] = []
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
                    ForEach(Array(codes.enumerated()), id: \.offset) { position, _ in
                        // A ZStack, not a VStack with the caption as a
                        // sibling row: module size is what decides whether a
                        // phone can focus on the code (measured versions
                        // 21-23 -> 0.308-0.330 mm/module in the old chrome,
                        // against a ~0.3 mm practical floor), so the caption
                        // overlays the code instead of taking its own row
                        // and shrinking it.
                        ZStack(alignment: .bottom) {
                            if let image = images[position] {
                                Image(uiImage: image)
                                    .interpolation(.none)
                                    .resizable()
                                    .scaledToFit()
                            }
                            if codes.count > 1 {
                                Text("\(position + 1) of \(codes.count)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .padding(.bottom, 2)
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
        // Hidden only once there are codes to show: the spec requires the QR
        // use the whole screen, because module size decides whether a phone
        // can focus on it. The empty state keeps its nav bar since there's
        // nothing there competing for the space.
        .toolbar(codes.isEmpty ? .visible : .hidden, for: .navigationBar)
        .onAppear {
            let entries = session.foodLog.entries
            capturedEntries = entries
            let generated = StandaloneExport.codes(for: entries)
            codes = generated
            images = generated.map { QRCodeImage.make(from: $0) }
        }
        .confirmationDialog("Clear the log?", isPresented: $confirmingClear) {
            Button("Clear", role: .destructive) {
                session.foodLog.remove(capturedEntries)
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
