import SwiftUI
import UIKit
import LiftCore

/// The "Send to LIFT" bookmarklet, and how to save it: what "Send recipes from
/// your browser" in Cook opens. The bookmarklet reads the recipe off a page the
/// browser already has open and opens `dugcanliftlift://recipe#r1...`
/// (`RecipeLink`), so a browser Safari's share sheet does not reach -- Chrome on
/// iPhone -- can still hand LIFT a recipe, and LIFT still fetches nothing.
///
/// The string is the kit's, never written here: `Resources/bookmarklets.json`
/// is a verbatim copy of `dugcanlift-kit/bookmarklet/bookmarklets.json`, pinned
/// by `bookmarklets.sha256` (`BookmarkletTests`). The kit's
/// `bookmarklet/README.md` is the contract.
struct FromBrowserView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var copied = false

    private let bookmarklet = Bookmarklet.liftApp()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.cardSpacing) {
                    // The kit's shared wording for this panel, word for word in
                    // every build (Doug reviews it): change it in all or none.
                    Text("Save this as a bookmark once. On any recipe page, tap the bookmark and the recipe opens here for you to check. LIFT never visits the page.")
                        .font(Theme.body)
                        .foregroundStyle(Theme.textPrimary)

                    LiftCard {
                        VStack(alignment: .leading, spacing: 8) {
                            step(1, "Tap Copy.")
                            step(2, "Bookmark any page.")
                            step(3, "Edit the bookmark. Name it Send to LIFT, and paste over its address.")
                            step(4, "On a recipe page, type Send to LIFT in the address bar and tap the bookmark.")
                        }
                    }

                    if let bookmarklet {
                        LiftCard(title: "Send to LIFT") {
                            VStack(alignment: .leading, spacing: 10) {
                                Button {
                                    UIPasteboard.general.string = bookmarklet
                                    copied = true
                                } label: {
                                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                                        .font(Theme.body.weight(.semibold))
                                        .foregroundStyle(Theme.accentText)
                                }
                                .buttonStyle(.plain)

                                // All of it, verbatim (never read as
                                // Markdown), in a box that scrolls: this is
                                // what Copy takes, the kit's to the byte.
                                ScrollView {
                                    Text(verbatim: bookmarklet)
                                        .scaledFont(size: 11, design: .monospaced)
                                        .foregroundStyle(Theme.textSecondary)
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .frame(maxHeight: 120)
                                .accessibilityLabel("Send to LIFT")
                            }
                        }
                    }

                    Text("In Safari, Share → LIFT does the same.")
                        .font(Theme.detail)
                        .foregroundStyle(Theme.textSecondary)
                }
                .padding(16)
                .readableContentWidth()
            }
            .liftScreen()
            .background(Theme.background)
            .navigationTitle("Send recipes from your browser")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        // Leaving LIFT for the browser closes this, so the recipe the
        // bookmark sends opens on a clear screen: `LiftApp` presents the review
        // from the root, and SwiftUI drops a second sheet beside this one.
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { dismiss() }
        }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number).")
                .font(Theme.body.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(Theme.accentText)
            Text(text)
                .font(Theme.body)
                .foregroundStyle(Theme.textPrimary)
        }
        // One element per step, so VoiceOver reads the step as a sentence.
        .accessibilityElement(children: .combine)
    }
}

/// The kit's bookmarklets, read from the bundled `bookmarklets.json`.
enum Bookmarklet {
    /// The `liftApp` target -- `dugcanliftlift://recipe#r1...`, LIFT iPhone's
    /// own scheme -- exactly as the kit wrote it, or nil when the resource is
    /// missing from the build.
    static func liftApp(in bundle: Bundle = .main) -> String? {
        guard let url = bundle.url(forResource: "bookmarklets", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object["liftApp"] as? String
    }
}
