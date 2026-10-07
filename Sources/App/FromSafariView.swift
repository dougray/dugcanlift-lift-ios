import SwiftUI
import LiftCore

/// What "Import from Safari" in Cook opens: how to send a recipe page to LIFT.
/// LIFT never fetches the page itself -- Safari hands over the recipe it
/// already has on screen -- so the way in is the share sheet, and this is where
/// a lifter who reaches for the button finds it.
struct FromSafariView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.cardSpacing) {
                    LiftCard(title: "Import from Safari") {
                        VStack(alignment: .leading, spacing: 8) {
                            step(1, "Open the recipe in Safari.")
                            step(2, "Tap Share, then LIFT.")
                            step(3, "Tap Add.")
                            step(4, "Come back to LIFT. The recipe opens for review.")
                        }
                    }
                    Text("Only Safari passes the recipe along. From another app or browser, copy the recipe's text and use Paste a recipe.")
                        .font(Theme.detail)
                        .foregroundStyle(Theme.textSecondary)
                }
                .padding(16)
            }
            .background(Theme.background)
            .navigationTitle("From Safari")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .liftAppearance()
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number).")
                .font(Theme.body.weight(.semibold))
                .foregroundStyle(Theme.accent)
            Text(text)
                .font(Theme.body)
                .foregroundStyle(Theme.textPrimary)
        }
        // One element per step, so VoiceOver reads "1. Open the recipe…" as a
        // sentence rather than the number on its own.
        .accessibilityElement(children: .combine)
    }
}
