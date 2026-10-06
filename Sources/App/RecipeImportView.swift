import SwiftUI
import SwiftData
import LiftCore

/// Review a recipe Safari handed over. LIFT never fetched the page: Safari's
/// `RecipePage.js` passed its JSON-LD to the share extension, which queued the
/// raw block (`PendingRecipeImports`), and this re-reads it with `LiftCore`'s
/// `RecipeJSONLD`.
///
/// Two steps, never one: what was read is shown next to the page it came from,
/// and nothing is saved until Save. `Recipe.sourceTranscript`'s contract is
/// that an import is reviewed before it is saved.
struct RecipeImportView: View {

    let item: PendingRecipeImports.Item

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var stage: Stage = .reading
    /// Set when the page stated no yield. Every macro is divided by this, so
    /// the parser leaves it nil and the reviewer supplies it here instead of
    /// the import inventing a number.
    @State private var servings: Double = 1
    @State private var pageDidNotStateServings = false
    @State private var showingSource = false

    private enum Stage {
        case reading
        case review(ImportedRecipe, URL)
        case failed(String)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch stage {
                    case .reading:
                        ProgressView().tint(Theme.accent).frame(maxWidth: .infinity)
                    case let .review(imported, url):
                        reviewCards(imported, url)
                    case let .failed(message):
                        failureCard(message)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .readableContentWidth()
            }
            .liftScreen()
            .background(Theme.background)
            .navigationTitle("Import from Safari")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if case let .review(imported, url) = stage {
                        Button("Save") { save(imported, from: url) }
                            .font(Theme.body.weight(.semibold))
                    }
                }
            }
            .onAppear(perform: load)
        }
    }

    // MARK: - Failure

    private func failureCard(_ message: String) -> some View {
        card("Could not import") {
            VStack(alignment: .leading, spacing: 12) {
                Text(message)
                    .font(Theme.detail)
                    .foregroundStyle(Theme.textSecondary)
                Button("Close") { dismiss() }
                    .font(Theme.body.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                    .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Review

    @ViewBuilder
    private func reviewCards(_ imported: ImportedRecipe, _ url: URL) -> some View {
        card(imported.name) {
            VStack(alignment: .leading, spacing: 10) {
                if let author = imported.author {
                    detail("By \(author)")
                }
                if let host = url.host() {
                    detail(host)
                }

                Stepper(value: $servings, in: 1...48, step: 1) {
                    Text(CookFormat.servingsLabel(servings))
                        .font(Theme.body)
                        .foregroundStyle(Theme.textPrimary)
                }

                if pageDidNotStateServings {
                    // Not a warning about a bad import -- the page genuinely
                    // never said. Saying so is the honest version of the
                    // parser refusing to guess.
                    detail("The page didn't say how many this serves. Set it before saving, or the macros below will be per whole dish.")
                }

                if let prep = imported.prepMinutes, let cook = imported.cookMinutes {
                    detail("\(prep) min prep · \(cook) min cook")
                } else if let prep = imported.prepMinutes {
                    detail("\(prep) min prep")
                } else if let cook = imported.cookMinutes {
                    detail("\(cook) min cook")
                }
            }
        }

        card("Ingredients (\(imported.ingredientLines.count))") {
            VStack(alignment: .leading, spacing: 8) {
                if imported.ingredientLines.isEmpty {
                    detail("None found. Without ingredients this will not build a shopping list.")
                }
                ForEach(Array(parsedIngredients(imported).enumerated()), id: \.offset) { _, parsed in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(parsed.displayText)
                            .font(Theme.body)
                            .foregroundStyle(Theme.textPrimary)
                        Spacer(minLength: 0)
                        if parsed.qty == nil {
                            // Kept, shown, and flagged. The shopping list falls
                            // back to the raw line for these.
                            Text("as written")
                                .font(Theme.detail)
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                }
            }
        }

        if !imported.steps.isEmpty {
            card("Method (\(imported.steps.count))") {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(imported.steps.enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("\(index + 1).")
                                .font(Theme.detail)
                                .foregroundStyle(Theme.accent)
                            Text(step)
                                .font(Theme.body)
                                .foregroundStyle(Theme.textPrimary)
                        }
                    }
                }
            }
        }

        if let nutrition = imported.nutritionPerServing {
            card("Macros per serving") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 14) {
                        Text("\(Int(nutrition.calories)) kcal")
                        Text("P \(Int(nutrition.proteinG))")
                        Text("C \(Int(nutrition.carbsG))")
                        Text("F \(Int(nutrition.fatG))")
                    }
                    .font(Theme.body)
                    .foregroundStyle(Theme.textPrimary)

                    if let details = NutrientDetailsDisplay.entryLine(nutrition) {
                        detail(details)
                    }

                    detail("The site's own figures, not resolved against the food database. Saved as an estimate.")
                }
            }
        }

        card("Source") {
            VStack(alignment: .leading, spacing: 10) {
                sourceAddress(url)

                Button(showingSource ? "Hide what the page published" : "Show what the page published") {
                    showingSource.toggle()
                }
                .font(Theme.detail)
                .foregroundStyle(Theme.accent)
                .buttonStyle(.plain)

                if showingSource {
                    // The whole point of keeping the transcript: a misread
                    // quantity is visible against its source before it is saved.
                    Text(imported.sourceTranscript)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    // MARK: - Load

    /// Re-reads the queued block. Nothing is fetched. An address that is not a
    /// URL, or a block that no longer parses, is said in words. A scheme other
    /// than http(s) is not a failure -- it is only never made tappable.
    private func load() {
        guard case .reading = stage else { return }
        guard let url = URL(string: item.pageURL),
              let imported = RecipeJSONLD.recipe(fromJSON: item.block) else {
            stage = .failed("This recipe couldn't be read. Share the page from Safari again, or use Paste a recipe.")
            return
        }
        servings = imported.servings ?? 1
        pageDidNotStateServings = imported.servings == nil
        stage = .review(imported, url)
    }

    // MARK: - Save

    private func parsedIngredients(_ imported: ImportedRecipe) -> [RecipeIngredient] {
        imported.ingredientLines.enumerated().map { index, line in
            IngredientParser.parse(line, sortOrder: index)
        }
    }

    /// Writes the reviewed import.
    ///
    /// Inserts the recipe and each ingredient, then wires the relationship, the
    /// same order `RecipeEditorView.save()` uses. The serving count comes from
    /// the stepper rather than the parse, so a page that never stated one ends
    /// up with a number a person chose.
    private func save(_ imported: ImportedRecipe, from url: URL) {
        var reviewed = imported
        reviewed.servings = servings

        let (recipe, ingredients) = reviewed.makeRecipe(sourceURL: url)
        context.insert(recipe)
        for ingredient in ingredients {
            ingredient.recipe = recipe
            context.insert(ingredient)
        }

        try? context.save()
        dismiss()
    }

    // MARK: - Small shared chrome

    /// The page's address. Tappable only for http and https: the address came
    /// from a page, and a `tel:` or app-scheme link is not something to open
    /// from a recipe's review.
    @ViewBuilder
    private func sourceAddress(_ url: URL) -> some View {
        let text = url.absoluteString
        if let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            Link(text, destination: url)
                .font(Theme.detail)
                .foregroundStyle(Theme.accent)
                .tint(Theme.accent)
                .lineLimit(2)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(text)
                .font(Theme.detail)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func card(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(Theme.sectionLabel)
                .foregroundStyle(Theme.accent)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.cardPadding)
        .liftCardBackground()
    }

    private func detail(_ text: String) -> some View {
        Text(text)
            .font(Theme.detail)
            .foregroundStyle(Theme.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
