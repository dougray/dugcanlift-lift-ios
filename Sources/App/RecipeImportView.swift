import SwiftUI
import SwiftData
import LiftCore

/// Import a recipe from a link.
///
/// Two steps, never one: fetch and parse, then show what was read next to the
/// source it came from and wait. `Recipe.sourceTranscript`'s contract is that
/// an import is reviewed before it is saved, so there is no "fetch and save"
/// path here and nothing is ever logged straight off a page.
///
/// The network call lives here rather than in `LiftCore`. `RecipeJSONLD` is
/// pure Foundation so the widget extension can still link the module, which
/// means the app target owns fetching — the same split as everything else that
/// needs the outside world.
struct RecipeImportView: View {

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var address = ""
    @State private var stage: Stage = .entry
    /// Set when the page stated no yield. Every macro is divided by this, so
    /// the parser leaves it nil and the reviewer supplies it here instead of
    /// the import inventing a number.
    @State private var servings: Double = 1
    @State private var pageDidNotStateServings = false
    @State private var showingSource = false

    private enum Stage {
        case entry
        case loading
        case review(ImportedRecipe, URL)
        case failed(String)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch stage {
                    case .entry:
                        entryCard
                    case .loading:
                        loadingCard
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
            .navigationTitle("Import a recipe")
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
        }
    }

    // MARK: - Entry

    private var entryCard: some View {
        card("Link") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Paste a recipe's web address. Most recipe sites publish their ingredients and method in a form this can read directly.")
                    .font(Theme.detail)
                    .foregroundStyle(Theme.textSecondary)

                TextField("https://", text: $address)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .font(Theme.body)
                    .foregroundStyle(Theme.textPrimary)
                    .onSubmit(fetch)

                Button(action: fetch) {
                    Text("Fetch recipe")
                        .font(Theme.body.weight(.semibold))
                        .foregroundStyle(Theme.onAccent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Theme.accent, in: .rect(cornerRadius: Theme.pillRadius))
                }
                .buttonStyle(.plain)
                .disabled(normalisedURL == nil)
                .opacity(normalisedURL == nil ? 0.4 : 1)
            }
        }
    }

    private var loadingCard: some View {
        card("Reading the page") {
            HStack(spacing: 10) {
                ProgressView().tint(Theme.accent)
                Text(address)
                    .font(Theme.detail)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private func failureCard(_ message: String) -> some View {
        card("Could not import") {
            VStack(alignment: .leading, spacing: 12) {
                Text(message)
                    .font(Theme.detail)
                    .foregroundStyle(Theme.textSecondary)
                Button("Try another link") { stage = .entry }
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
                Text(url.absoluteString)
                    .font(Theme.detail)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
                    .truncationMode(.middle)

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

    // MARK: - Fetch

    /// Accepts "example.com/recipe" as well as a full address, because that is
    /// what comes off a share sheet or a paste half of the time.
    private var normalisedURL: URL? {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let url = URL(string: candidate), let host = url.host(), host.contains(".") else { return nil }
        return url
    }

    private func fetch() {
        guard let url = normalisedURL else { return }
        stage = .loading
        showingSource = false

        Task {
            do {
                let html = try await Self.loadPage(at: url)
                guard let imported = RecipeJSONLD.recipe(fromHTML: html) else {
                    stage = .failed("That page doesn't publish a recipe in a form this can read. Sites that show a recipe card usually do; a blog post about a recipe often doesn't. You can still add it by hand.")
                    return
                }
                servings = imported.servings ?? 1
                pageDidNotStateServings = imported.servings == nil
                stage = .review(imported, url)
            } catch {
                stage = .failed("Couldn't load that page. \(error.localizedDescription)")
            }
        }
    }

    /// Fetches the page and decodes it as text.
    ///
    /// The User-Agent names LIFT rather than impersonating a browser. Some
    /// sites will refuse it; being refused is a better failure than pretending
    /// to be something else, and the error above says plainly what happened.
    ///
    /// Encoding is guessed in the order that actually occurs: UTF-8 for almost
    /// everything, then Windows-1252 for the older food blogs that never
    /// declared one. A page that decodes as neither is reported rather than
    /// rendered as mojibake.
    private static func loadPage(at url: URL) async throws -> String {
        var request = URLRequest(url: url)
        request.setValue("LIFT (recipe import)", forHTTPHeaderField: "User-Agent")
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20

        let (data, response) = try await URLSession.shared.data(for: request)

        if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
            throw ImportError.badStatus(http.statusCode)
        }
        if let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252) {
            return text
        }
        throw ImportError.undecodable
    }

    private enum ImportError: LocalizedError {
        case badStatus(Int)
        case undecodable

        var errorDescription: String? {
            switch self {
            case let .badStatus(code): return "The site answered with \(code)."
            case .undecodable: return "The page wasn't readable as text."
            }
        }
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
