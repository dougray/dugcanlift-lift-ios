import SwiftUI
import SwiftData

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

    @State private var name = ""
    @State private var servings: Double = 1
    @State private var ingredientText = ""
    @State private var stepText = ""

    @State private var calories = ""
    @State private var protein = ""
    @State private var carbs = ""
    @State private var fat = ""

    private var isEditing: Bool { recipe != nil }

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
                            Text(servingsLabel(servings))
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

        if let nutrition = recipe.nutritionPerServing {
            calories = trimmed(nutrition.calories)
            protein = trimmed(nutrition.proteinG)
            carbs = trimmed(nutrition.carbsG)
            fat = trimmed(nutrition.fatG)
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

// MARK: - Parsing

/// Pulls a quantity and unit off the front of an ingredient line.
///
/// Deliberately small. It handles the shapes people actually type and gives up
/// cleanly on everything else, leaving `item` nil so the shopping list shows
/// the raw line instead. Guessing harder here would produce confident wrong
/// quantities, which is worse than an unparsed line the reader can see.
enum IngredientParser {

    /// Grouping key for an ingredient with no unit — "2 eggs", "1 banana".
    ///
    /// A sentinel, not a unit. It keeps counts in their own bucket during
    /// aggregation, and the shopping list drops it when printing, because
    /// "2 x banana" is not how anyone writes a shopping list.
    static let countUnit = "\u{0000}count"

    private static let units: Set<String> = [
        "g", "kg", "mg", "ml", "l",
        "tsp", "tbsp", "cup", "cups", "oz", "lb", "lbs",
        "clove", "cloves", "slice", "slices", "scoop", "scoops",
        "can", "cans", "pinch", "handful"
    ]

    static func parse(_ raw: String, sortOrder: Int) -> RecipeIngredient {
        var rest = raw[...]
        let quantity = takeQuantity(&rest)

        guard let quantity else {
            return RecipeIngredient(rawText: raw, sortOrder: sortOrder)
        }

        var unit: String?
        let words = rest.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        if let first = words.first {
            let candidate = String(first).lowercased().trimmingCharacters(in: .punctuationCharacters)
            if units.contains(candidate) {
                unit = candidate
                rest = words.count > 1 ? words[1] : ""[...]
            }
        }

        let item = rest.trimmingCharacters(in: .whitespaces)
        guard !item.isEmpty else {
            return RecipeIngredient(rawText: raw, sortOrder: sortOrder)
        }

        return RecipeIngredient(
            rawText: raw,
            item: item,
            qty: quantity,
            // No unit means a count — "2 eggs". It still needs a key, so that
            // two eggs are never added to two cups of anything, but it is not
            // a unit and must never be printed as one. See `countUnit`.
            unit: unit ?? countUnit,
            grams: unit == "g" ? quantity : nil,
            sortOrder: sortOrder
        )
    }

    /// Reads a leading number, including "1/2" and "1 1/2".
    private static func takeQuantity(_ text: inout Substring) -> Double? {
        text = text.drop(while: { $0 == " " })[...]

        func takeNumber() -> Double? {
            let digits = text.prefix { $0.isNumber || $0 == "." }
            guard !digits.isEmpty, let value = Double(digits) else { return nil }
            text = text.dropFirst(digits.count)
            return value
        }

        guard var value = takeNumber() else { return nil }

        if text.first == "/" {
            text = text.dropFirst()
            guard let denominator = takeNumber(), denominator != 0 else { return nil }
            value /= denominator
        } else if text.first == " " {
            // "1 1/2" — a whole number followed by a fraction.
            let save = text
            text = text.dropFirst()
            if let whole = takeNumber(), text.first == "/" {
                text = text.dropFirst()
                if let denominator = takeNumber(), denominator != 0 {
                    value += whole / denominator
                } else {
                    text = save
                }
            } else {
                text = save
            }
        }

        text = text.drop(while: { $0 == " " })[...]
        return value
    }
}
