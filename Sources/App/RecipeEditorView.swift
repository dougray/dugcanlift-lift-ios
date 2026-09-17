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
    /// Optional on `NutritionFacts` where the other four are not, so a blank
    /// here stays nil rather than becoming a measured zero: a dish whose
    /// ingredients carry no fibre data must not claim to have none.
    @State private var fiber = ""
    /// Saturated fat, sugar and sodium, under "More nutrients". Tracked, never
    /// targeted; blank stays nil for the same reason fibre does.
    @State private var saturatedFat = ""
    @State private var sugar = ""
    @State private var sodium = ""
    @State private var showingMoreNutrients = false

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
                .readableContentWidth()
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

            // Calories on its own row, the four gram figures under it. Five
            // across one row crushes each to about 70pt at iPhone width, and
            // "P / C / F" only fits because it says almost nothing -- a person
            // reading their own recipe should not have to decode initials.
            macroField("Calories", unit: "kcal", text: $calories)

            HStack(spacing: 10) {
                macroField("Protein", unit: "g", text: $protein)
                macroField("Carbs", unit: "g", text: $carbs)
                macroField("Fat", unit: "g", text: $fat)
                macroField("Fibre", unit: "g", text: $fiber)
            }

            moreNutrients
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.cardPadding)
        .liftCardBackground()
    }

    /// Collapsed unless the recipe already has one of the three, so an
    /// imported recipe shows what its page said without a tap.
    private var moreNutrients: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { showingMoreNutrients.toggle() }
            } label: {
                HStack {
                    Text("More nutrients")
                        .font(Theme.body.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .rotationEffect(.degrees(showingMoreNutrients ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, 6)
            .accessibilityValue(showingMoreNutrients ? "Expanded" : "Collapsed")

            if showingMoreNutrients {
                Text("Per serving. No goals — blank stays unknown.")
                    .font(Theme.detail)
                    .foregroundStyle(Theme.textSecondary)
                HStack(alignment: .top, spacing: 10) {
                    macroField("Saturated fat", unit: "g", text: $saturatedFat)
                    macroField("Sugar", unit: "g", text: $sugar)
                    macroField("Sodium", unit: "mg", text: $sodium)
                }
            }
        }
    }

    /// The label names the macro and the unit says what the number is in.
    ///
    /// Both are `Text` above the field rather than a placeholder, because a
    /// placeholder vanishes the moment the field has a value -- which is
    /// precisely when someone needs to know which number is fat and which is
    /// fibre.
    private func macroField(_ label: String, unit: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(label) (\(unit))")
                .font(Theme.detail)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            TextField("—", text: text)
                .keyboardType(.decimalPad)
                .font(Theme.body)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
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
        .liftCardBackground()
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
            fiber = nutrition.fiberG.map(CookFormat.trimmed) ?? ""
            saturatedFat = nutrition.saturatedFatG.map(CookFormat.trimmed) ?? ""
            sugar = nutrition.sugarG.map(CookFormat.trimmed) ?? ""
            sodium = nutrition.sodiumMg.map(CookFormat.trimmed) ?? ""
            showingMoreNutrients = nutrition.saturatedFatG != nil || nutrition.sugarG != nil
                || nutrition.sodiumMg != nil
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
        target.nutritionPerServing = RecipeMacroEntry.entered(
            calories: calories, protein: protein, carbs: carbs, fat: fat, fiber: fiber,
            saturatedFat: saturatedFat, sugar: sugar, sodium: sodium)

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

    private func lines(from text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
