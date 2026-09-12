import SwiftUI
import SwiftData
import LiftCore

/// Create or edit a recipe by hand.
///
/// Ingredients are typed as free text — "2 tbsp olive oil" — and parsed into
/// quantity, unit and item on save. The raw line is always kept: it is what the
/// person checks the parse against, and what the shopping list falls back to
/// when the parse fails. A parser that quietly discards what it could not read
/// is worse than no parser.
struct RecipeEditorView: View {

    let recipe: Recipe?

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @AppStorage("servingUnit") private var servingUnitRaw = ServingUnit.grams.rawValue

    @State private var name = ""
    @State private var servings: Double = 1
    @State private var ingredientText = ""
    @State private var stepText = ""

    @State private var calories = ""
    @State private var protein = ""
    @State private var carbs = ""
    @State private var fat = ""

    /// Displayed and entered in the person's preferred `ServingUnit`, not
    /// necessarily grams — converted to/from `Recipe.totalWeightGrams` at
    /// load/save time, the same way `FoodSearchView`'s amount field converts.
    @State private var totalWeightText = ""

    private var isEditing: Bool { recipe != nil }
    private var servingUnit: ServingUnit { ServingUnit(rawValue: servingUnitRaw) ?? .grams }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    field("Name") {
                        TextField("Overnight oats", text: $name)
                            .textInputAutocapitalization(.sentences)
                    }

                    field("Servings") {
                        Stepper(value: $servings, in: 1...24, step: 1) {
                            Text(CookFormat.servingsLabel(servings))
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }

                    field(
                        "Total weight",
                        hint: "Optional. Set this along with macros below to enable gram-based logging when planning this recipe."
                    ) {
                        HStack {
                            TextField("0", text: $totalWeightText)
                                .keyboardType(.decimalPad)
                            Text(servingUnit.abbreviation)
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }

                    field("Ingredients", hint: "One per line, as you'd say them — \"2 tbsp olive oil\".") {
                        TextEditor(text: $ingredientText)
                            .frame(minHeight: 130)
                            .scrollContentBackground(.hidden)
                    }

                    field("Method", hint: "One step per line. Optional.") {
                        TextEditor(text: $stepText)
                            .frame(minHeight: 100)
                            .scrollContentBackground(.hidden)
                    }

                    macrosSection

                    if isEditing {
                        Button("Delete recipe", role: .destructive) { delete() }
                            .font(Theme.body)
                            .padding(.top, 4)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
            .liftScreen()
            .background(Theme.background)
            .navigationTitle(isEditing ? "Edit recipe" : "New recipe")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear(perform: load)
        }
    }

    private var macrosSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Macros per serving")
                .font(Theme.sectionLabel)
                .foregroundStyle(Theme.accent)

            Text("Leave blank if you don't know them. Blank stays unknown — it will not log as zero.")
                .font(Theme.detail)
                .foregroundStyle(Theme.textSecondary)

            HStack(spacing: 10) {
                macroField("kcal", text: $calories)
                macroField("P", text: $protein)
                macroField("C", text: $carbs)
                macroField("F", text: $fat)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.cardPadding)
        .background(Theme.surface, in: .rect(cornerRadius: Theme.cardRadius))
    }

    private func macroField(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(Theme.detail)
                .foregroundStyle(Theme.textSecondary)
            TextField("—", text: text)
                .keyboardType(.decimalPad)
                .font(Theme.body)
                .padding(8)
                .background(Theme.background, in: .rect(cornerRadius: Theme.chipRadius))
        }
    }

    private func field<Content: View>(
        _ label: String,
        hint: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(Theme.sectionLabel)
                .foregroundStyle(Theme.accent)

            if let hint {
                Text(hint)
                    .font(Theme.detail)
                    .foregroundStyle(Theme.textSecondary)
            }

            content()
                .font(Theme.body)
                .foregroundStyle(Theme.textPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.cardPadding)
        .background(Theme.surface, in: .rect(cornerRadius: Theme.cardRadius))
    }

    // MARK: - Load and save

    private func load() {
        guard let recipe else { return }
        name = recipe.name
        servings = recipe.servings
        ingredientText = (recipe.ingredients ?? [])
            .sorted { $0.sortOrder < $1.sortOrder }
            .map(\.rawText)
            .joined(separator: "\n")
        stepText = recipe.steps.joined(separator: "\n")

        if let totalWeightGrams = recipe.totalWeightGrams {
            totalWeightText = CookFormat.trimmed(servingUnit.fromGrams(totalWeightGrams))
        }

        if let nutrition = recipe.nutritionPerServing {
            calories = CookFormat.trimmed(nutrition.calories)
            protein = CookFormat.trimmed(nutrition.proteinG)
            carbs = CookFormat.trimmed(nutrition.carbsG)
            fat = CookFormat.trimmed(nutrition.fatG)
        }
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { return }

        let target = recipe ?? {
            let fresh = Recipe(name: trimmedName, servings: servings)
            context.insert(fresh)
            return fresh
        }()

        target.name = trimmedName
        target.servings = servings
        target.steps = lines(from: stepText)
        target.nutritionPerServing = enteredNutrition()

        // Empty/unparseable stays nil — a recipe without a total weight
        // simply keeps using the legacy servings-based path. Otherwise
        // convert from the person's preferred `ServingUnit` into the
        // canonical grams `Recipe.totalWeightGrams` stores, exactly the way
        // `FoodSearchView.log(_:)` converts its own amount field.
        if let entered = Double(totalWeightText.trimmingCharacters(in: .whitespaces)) {
            target.totalWeightGrams = servingUnit.toGrams(entered)
        } else {
            target.totalWeightGrams = nil
        }

        // Replace rather than diff. Ingredients have no identity the user can
        // see — they typed a block of text — so matching old rows to new lines
        // would be guesswork.
        for existing in target.ingredients ?? [] { context.delete(existing) }
        target.ingredients = []
        for (index, raw) in lines(from: ingredientText).enumerated() {
            let parsed = IngredientParser.parse(raw, sortOrder: index)
            parsed.recipe = target
            context.insert(parsed)
        }

        try? context.save()
        dismiss()
    }

    private func delete() {
        guard let recipe else { return }
        context.delete(recipe)
        try? context.save()
        dismiss()
    }

    /// nil unless something was actually typed — an untouched form must not
    /// write zeros, which would later log as a zero-calorie meal.
    private func enteredNutrition() -> NutritionFacts? {
        let values = [calories, protein, carbs, fat].map {
            Double($0.trimmingCharacters(in: .whitespaces))
        }
        guard values.contains(where: { $0 != nil }) else { return nil }
        return NutritionFacts(
            calories: values[0] ?? 0,
            proteinG: values[1] ?? 0,
            carbsG: values[2] ?? 0,
            fatG: values[3] ?? 0
        )
    }

    private func lines(from text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
