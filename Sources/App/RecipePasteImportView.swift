import SwiftUI
import SwiftData
import LiftCore

/// Import a recipe by pasting the text of one — a video caption, an email, a
/// card off the fridge retyped.
///
/// The fourth way into COOK, and the second that needs no connection. It
/// exists because `RecipeImportView` can only read a page that labelled its
/// own ingredients: social video never does. TikTok, Instagram and Reels
/// publish no schema.org `Recipe` at all, YouTube publishes a `VideoObject`,
/// and all of them hand a plain fetch a JavaScript shell. The recipe in those
/// is prose in a caption, so this reads the prose.
///
/// **An editor, not a review, and that difference is the safety argument.**
/// `RecipeImportView` reviews because JSON-LD is labelled — the publisher
/// already said which strings are ingredients, so there is a right answer to
/// show. A caption has no labels, so `LiftCore.CaptionRecipe` only ever
/// *proposes* a split and the cook corrects it here. A wrong split costs an
/// edit; it cannot cost a number, because `IngredientParser` still reads the
/// quantities on save from whatever text was finally approved.
///
/// Two plain text boxes rather than a per-line ingredient/step picker. The
/// picker is a day of interface to solve what cut-and-paste already solves,
/// and reparsing the boxes on save keeps the same contract every other
/// importer here follows: the raw text is what a line means.
///
/// Nothing is costed, matching `RecipeImportView`. A caption states no macros,
/// so the recipe saves without them and the editor is where they are filled
/// in — blank stays blank rather than becoming a zero-calorie dinner.
struct RecipePasteImportView: View {

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var pasted = ""
    @State private var parsed: ParsedCaption?

    @State private var name = ""
    @State private var ingredientsText = ""
    @State private var methodText = ""
    /// Only ever from an explicit "serves 4". Every macro added later divides
    /// by this, so a guessed yield is worse than an unanswered one.
    @State private var servings: Double = 1
    @State private var yieldWasStated = false
    @State private var note = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if parsed == nil { entryCard } else { editorCards }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
            .liftScreen()
            .background(Theme.background)
            .navigationTitle(parsed == nil ? "Paste a recipe" : "Check it over")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if parsed != nil {
                        Button("Save") { save() }
                            .font(Theme.body.weight(.semibold))
                            .disabled(!canSave)
                    }
                }
            }
        }
    }

    // MARK: - Entry

    private var entryCard: some View {
        card("Paste it in") {
            VStack(alignment: .leading, spacing: 12) {
                TextEditor(text: $pasted)
                    .frame(minHeight: 200)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(Theme.background, in: .rect(cornerRadius: 10))
                    .font(Theme.body)
                    .foregroundStyle(Theme.textPrimary)

                HStack(spacing: 12) {
                    // `PasteButton` rather than a Button reading
                    // `UIPasteboard.general`: reading the pasteboard in code
                    // raises iOS's "Allow Paste?" alert every time, and
                    // tapping the system button is itself the consent.
                    PasteButton(payloadType: String.self) { strings in
                        guard let text = strings.first, !text.isEmpty else { return }
                        pasted = text
                    }
                    .labelStyle(.titleAndIcon)
                    .tint(Theme.accent)

                    Spacer()

                    Button("Read it") { read() }
                        .font(Theme.body.weight(.semibold))
                        .foregroundStyle(canRead ? Theme.accent : Theme.textSecondary)
                        .disabled(!canRead)
                }

                if !note.isEmpty { detail(note) }

                // Says plainly where this is the wrong tool, so a recipe site
                // does not get pasted in as one long ingredient.
                detail("For a recipe written out as text — a video caption, an email, a "
                       + "handwritten card. For a recipe website, \"Import from a link\" "
                       + "reads the page itself and gets more of it.")
            }
        }
    }

    private var canRead: Bool {
        !pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Editor

    @ViewBuilder
    private var editorCards: some View {
        card("Recipe") {
            VStack(alignment: .leading, spacing: 12) {
                TextField("Name", text: $name)
                    .font(Theme.body)
                    .foregroundStyle(Theme.textPrimary)
                    .padding(10)
                    .background(Theme.background, in: .rect(cornerRadius: 10))

                Stepper(value: $servings, in: 1...48, step: 1) {
                    Text(CookFormat.servingsLabel(servings))
                        .font(Theme.body)
                        .foregroundStyle(Theme.textPrimary)
                }

                if !yieldWasStated {
                    detail("The text didn't say how many this serves. Set it before saving — "
                           + "every macro you add later divides by it.")
                }
            }
        }

        card("Ingredients (\(ingredientCount))") {
            VStack(alignment: .leading, spacing: 10) {
                editor($ingredientsText, minHeight: 170)
                detail(splitAdvice)
            }
        }

        card("Method") {
            VStack(alignment: .leading, spacing: 10) {
                editor($methodText, minHeight: 130)
                detail("One step per line. Optional.")
            }
        }

        card("Macros") {
            detail("A caption states none, so this saves without them. Open the recipe "
                   + "afterwards and they fill in from the ingredients that can be "
                   + "looked up.")
        }

        Button("Start over") { reset() }
            .font(Theme.detail)
            .foregroundStyle(Theme.accent)
            .buttonStyle(.plain)
    }

    private func editor(_ text: Binding<String>, minHeight: CGFloat) -> some View {
        TextEditor(text: text)
            .frame(minHeight: minHeight)
            .scrollContentBackground(.hidden)
            .padding(8)
            .background(Theme.background, in: .rect(cornerRadius: 10))
            .font(Theme.body)
            .foregroundStyle(Theme.textPrimary)
    }

    /// What to say about the split — the one thing to check, and the one thing
    /// the parser is honest about not knowing.
    private var splitAdvice: String {
        switch parsed?.split {
        case .labelled:
            return "One per line. Split on the headings in the text — check it read them right."
        case .inferred:
            return "One per line. The text labelled one section and this worked out the rest, "
                 + "so check the division before saving."
        case .unsorted, .none:
            return "One per line. The text had no headings, so everything landed here — cut "
                 + "any method steps out and paste them below."
        }
    }

    private var ingredientCount: Int { CaptionRecipe.lines(from: ingredientsText).count }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && ingredientCount > 0
    }

    // MARK: - Behaviour

    private func read() {
        let found = CaptionRecipe.parse(pasted)
        guard !found.isEmpty else {
            note = "Nothing in that reads as a recipe. Paste the ingredients and steps as text."
            return
        }

        name = found.name ?? ""
        ingredientsText = found.ingredientLines.joined(separator: "\n")
        methodText = found.steps.joined(separator: "\n")
        servings = found.servings ?? 1
        yieldWasStated = found.servings != nil
        note = ""
        parsed = found
    }

    private func reset() {
        parsed = nil
        name = ""
        ingredientsText = ""
        methodText = ""
        servings = 1
        note = ""
    }

    /// Writes what was approved.
    ///
    /// The boxes are reparsed here rather than tracked as arrays while they
    /// were edited: the text is the contract, and reading it back once at the
    /// end is what stops an edit and a parse disagreeing.
    ///
    /// No source URL — a caption has no address, and inventing one would leave
    /// a link in the recipe that goes nowhere.
    private func save() {
        guard let parsed else { return }

        let ingredientLines = CaptionRecipe.lines(from: ingredientsText)
        guard !ingredientLines.isEmpty else { return }

        let imported = parsed.imported(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            ingredientLines: ingredientLines,
            steps: CaptionRecipe.lines(from: methodText),
            servings: servings)

        let (recipe, ingredients) = imported.makeRecipe(sourceURL: nil)
        context.insert(recipe)
        for ingredient in ingredients {
            ingredient.recipe = recipe
            context.insert(ingredient)
        }

        try? context.save()
        dismiss()
    }

    // MARK: - Chrome

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
