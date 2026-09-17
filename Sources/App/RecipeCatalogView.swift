import SwiftUI
import SwiftData
import LiftCore
import LiftReference

/// Browse the bundled recipe catalogue and copy one into your own library.
///
/// The third way into COOK, beside writing a recipe and importing a link. This
/// one needs no network and no typing: 622 recipes ship in `recipes.db`.
///
/// Nothing here is in the library until **Add** is tapped. A catalogue recipe
/// is reference data, the same as a food or an exercise, and browsing it must
/// not quietly fill someone's recipe list.
struct RecipeCatalogView: View {

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var entries: [CatalogEntry] = []
    @State private var loadFailed = false
    @State private var selected: CatalogEntry?
    /// Only consulted for a recipe whose source stated no yield. A published
    /// per-serving figure is never rescaled by it.
    @State private var servings: Double = 4
    @State private var showingCredits = false
    @State private var credits: [String] = []

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.cardSpacing) {
                    if let selected {
                        detail(selected)
                    } else {
                        list
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .readableContentWidth()
            }
            .liftScreen()
            .background(Theme.background)
            .navigationTitle(selected == nil ? "Recipe catalogue" : "Add recipe")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "Search 600+ recipes")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if selected == nil {
                        Button("Done") { dismiss() }
                    } else {
                        Button("Back") { selected = nil }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if let selected {
                        Button("Add") { add(selected) }
                            .font(Theme.body.weight(.semibold))
                    }
                }
            }
            .task(id: query) { await load() }
            .task { credits = (try? await ReferenceDatabase.shared.recipeAttributions()) ?? [] }
        }
    }

    // MARK: - List

    @ViewBuilder
    private var list: some View {
        if loadFailed {
            card { detailText("The recipe catalogue could not be opened.") }
        } else if entries.isEmpty {
            card {
                detailText(query.trimmingCharacters(in: .whitespaces).count >= 2
                           ? "Nothing matches that."
                           : "Loading…")
            }
        } else {
            ForEach(entries) { entry in
                Button { open(entry) } label: { row(entry) }
                    .buttonStyle(.plain)
            }
        }

        // The credit is the CC BY-SA obligation, not decoration, so it sits on
        // the screen that shows the data rather than buried in a settings page.
        if !credits.isEmpty {
            Button(showingCredits ? "Hide credits" : "Credits and licences") {
                showingCredits.toggle()
            }
            .font(Theme.detail)
            .foregroundStyle(Theme.accent)
            .buttonStyle(.plain)
            .padding(.top, 8)

            if showingCredits {
                card {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(credits, id: \.self) { detailText($0) }
                    }
                }
            }
        }
    }

    private func row(_ entry: CatalogEntry) -> some View {
        let recipe = entry.recipe
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(recipe.name)
                    .font(Theme.cardTitle)
                    .foregroundStyle(Theme.accent)
                Spacer(minLength: 8)
                if let servings = recipe.servings {
                    Text(CookFormat.servingsLabel(servings))
                        .font(Theme.detail)
                        .foregroundStyle(Theme.textSecondary)
                }
            }

            if let calories = recipe.caloriesPerServing {
                Text("\(Int(calories)) kcal per serving")
                    .font(Theme.detail)
                    .foregroundStyle(Theme.textSecondary)
            } else if recipe.needsServings {
                // Said here rather than only in the detail, so a browsing eye
                // never reads a whole-dish number as a portion.
                Text("Macros for the whole dish")
                    .font(Theme.detail)
                    .foregroundStyle(Theme.textSecondary)
            } else {
                Text("No macros")
                    .font(Theme.detail)
                    .foregroundStyle(Theme.textSecondary)
            }

            Text("\(entry.ingredientLines.count) ingredients")
                .font(Theme.detail)
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.cardPadding)
        .liftCardBackground()
    }

    // MARK: - Detail

    @ViewBuilder
    private func detail(_ entry: CatalogEntry) -> some View {
        let recipe = entry.recipe

        card {
            VStack(alignment: .leading, spacing: 10) {
                Text(recipe.name)
                    .font(Theme.cardTitle)
                    .foregroundStyle(Theme.accent)
                if let summary = recipe.summary { detailText(summary) }

                if recipe.needsServings {
                    Stepper(value: $servings, in: 1...48, step: 1) {
                        Text(CookFormat.servingsLabel(servings))
                            .font(Theme.body)
                            .foregroundStyle(Theme.textPrimary)
                    }
                    detailText("This book states no yield, so the macros below are for the whole dish. Set how many it serves and they divide.")
                } else if let stated = recipe.servings {
                    detailText(CookFormat.servingsLabel(stated))
                }

                if let prep = recipe.prepMinutes, let cook = recipe.cookMinutes {
                    detailText("\(prep) min prep · \(cook) min cook")
                }
            }
        }

        card {
            VStack(alignment: .leading, spacing: 8) {
                Text("Ingredients (\(entry.ingredientLines.count))")
                    .font(Theme.sectionLabel)
                    .foregroundStyle(Theme.accent)
                ForEach(Array(entry.ingredientLines.enumerated()), id: \.offset) { index, line in
                    let parsed = IngredientParser.parse(line, sortOrder: index)
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(parsed.displayText)
                            .font(Theme.body)
                            .foregroundStyle(Theme.textPrimary)
                        Spacer(minLength: 0)
                        if parsed.qty == nil {
                            Text("as written")
                                .font(Theme.detail)
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                }
            }
        }

        if !recipe.stepLines.isEmpty {
            card {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Method (\(recipe.stepLines.count))")
                        .font(Theme.sectionLabel)
                        .foregroundStyle(Theme.accent)
                    ForEach(Array(recipe.stepLines.enumerated()), id: \.offset) { index, step in
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

        card {
            VStack(alignment: .leading, spacing: 8) {
                Text("Macros")
                    .font(Theme.sectionLabel)
                    .foregroundStyle(Theme.accent)

                if let facts = recipe.nutrition(servings: servings) {
                    Text("\(Int(facts.calories)) kcal · P \(Int(facts.proteinG)) · C \(Int(facts.carbsG)) · F \(Int(facts.fatG))")
                        .font(Theme.body)
                        .foregroundStyle(Theme.textPrimary)
                    detailText(recipe.needsServings
                               ? "Per serving at \(CookFormat.servingsLabel(servings))."
                               : "Per serving, as published.")
                } else {
                    detailText("None.")
                }

                if let note = recipe.nutritionNote { detailText(note) }
            }
        }

        card {
            VStack(alignment: .leading, spacing: 6) {
                Text("Source")
                    .font(Theme.sectionLabel)
                    .foregroundStyle(Theme.accent)
                detailText(recipe.attribution)
                detailText(recipe.license)
            }
        }
    }

    // MARK: - Behaviour

    private func open(_ entry: CatalogEntry) {
        // Seeded from the source when it stated one, so the stepper starts
        // somewhere sensible rather than at a default the reader must undo.
        servings = entry.recipe.servings ?? 4
        selected = entry
    }

    /// Debounced the same way `FoodSearchView` does, and for the same reason:
    /// a keystroke is not a query.
    private func load() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

        if !trimmed.isEmpty && trimmed.count < 2 { return }
        if !trimmed.isEmpty {
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
        }

        do {
            let found = trimmed.count >= 2
                ? try await ReferenceDatabase.shared.searchRecipes(trimmed)
                : try await ReferenceDatabase.shared.browseRecipes()
            guard !Task.isCancelled else { return }
            entries = found
            loadFailed = false
        } catch {
            entries = []
            loadFailed = true
        }
    }

    /// Copies the entry into the library.
    ///
    /// Inserts the recipe and each ingredient, then wires the relationship --
    /// the order `RecipeEditorView.save()` uses. No widget reload: a `Recipe`
    /// is not widget content, only a `PlannedMeal` logged from one is.
    private func add(_ entry: CatalogEntry) {
        let (recipe, ingredients) = entry.makeRecipe(servings: entry.recipe.servings ?? servings)
        context.insert(recipe)
        for ingredient in ingredients {
            ingredient.recipe = recipe
            context.insert(ingredient)
        }
        try? context.save()
        dismiss()
    }

    // MARK: - Chrome

    private func card(@ViewBuilder content: () -> some View) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.cardPadding)
            .liftCardBackground()
    }

    private func detailText(_ text: String) -> some View {
        Text(text)
            .font(Theme.detail)
            .foregroundStyle(Theme.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
