import SwiftUI
import SwiftData
import WidgetKit

/// COOK — recipes, the week's plan, and the shopping list that falls out of it.
///
/// The client half. The trainer half is the COOK page in Coach, which authors
/// the same `PlannedMeal` shapes and sends them here as a link.
///
/// Three segments rather than three tabs: they are one workflow — pick recipes,
/// place them on days, shop for what that adds up to — and splitting them
/// across the top bar would suggest they are separate places.
struct CookView: View {

    enum Section: String, CaseIterable, Identifiable {
        case recipes = "Recipes"
        case plan = "Plan"
        case shopping = "Shopping"

        var id: String { rawValue }
    }

    @State private var section: Section = .recipes

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $section) {
                ForEach(Section.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            switch section {
            case .recipes:  RecipeListView()
            case .plan:     MealPlanView()
            case .shopping: ShoppingListView()
            }
        }
        .liftScreen()
    }
}

// MARK: - Recipes

struct RecipeListView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Recipe.name) private var recipes: [Recipe]

    @State private var editing: Recipe?
    @State private var creatingNew = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.cardSpacing) {
                Button {
                    creatingNew = true
                } label: {
                    Label("New recipe", systemImage: "plus")
                        .font(Theme.body.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Theme.cardPadding)
                        .background(Theme.surface, in: .rect(cornerRadius: Theme.cardRadius))
                }
                .buttonStyle(.plain)

                if recipes.isEmpty {
                    Text("No recipes yet. Add one you already cook — the plan and the shopping list build themselves from here.")
                        .font(Theme.detail)
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.top, 4)
                } else {
                    ForEach(recipes) { recipe in
                        Button { editing = recipe } label: { row(recipe) }
                            .buttonStyle(.plain)
                    }
                }

                // Below the list on purpose: it must not appear in the top of
                // a screenshot. DEBUG only, so it is never in a shipped build.
                #if DEBUG
                Button("Load sample recipes") {
                    CookSampleData.load(into: context)
                }
                .font(Theme.detail)
                .foregroundStyle(Theme.textSecondary.opacity(0.5))
                .buttonStyle(.plain)
                .padding(.top, 24)
                #endif
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 40)
        }
        .sheet(isPresented: $creatingNew) {
            RecipeEditorView(recipe: nil).preferredColorScheme(.dark)
        }
        .sheet(item: $editing) { recipe in
            RecipeEditorView(recipe: recipe).preferredColorScheme(.dark)
        }
    }

    private func row(_ recipe: Recipe) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(recipe.name)
                    .font(Theme.cardTitle)
                    .foregroundStyle(Theme.accent)
                Spacer()
                Text(servingsLabel(recipe.servings))
                    .font(Theme.detail)
                    .foregroundStyle(Theme.textSecondary)
            }

            if let nutrition = recipe.nutritionPerServing {
                HStack(spacing: 10) {
                    Text("\(Int(nutrition.calories)) kcal")
                    Text("P \(Int(nutrition.proteinG))")
                    Text("C \(Int(nutrition.carbsG))")
                    Text("F \(Int(nutrition.fatG))")
                    if recipe.nutritionIsEstimated {
                        Text("estimated")
                            .foregroundStyle(Theme.accentMuted)
                    }
                }
                .font(Theme.detail)
                .foregroundStyle(Theme.textSecondary)
            } else {
                // Deliberately not "0 kcal". An unknown that renders as zero
                // becomes a zero-calorie dinner in someone's day total.
                Text("Macros not set")
                    .font(Theme.detail)
                    .foregroundStyle(Theme.textSecondary)
            }

            let count = recipe.ingredients?.count ?? 0
            if count > 0 {
                Text("\(count) ingredient\(count == 1 ? "" : "s")")
                    .font(Theme.detail)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.cardPadding)
        .background(Theme.surface, in: .rect(cornerRadius: Theme.cardRadius))
    }
}

// MARK: - Plan

struct MealPlanView: View {
    @Environment(\.modelContext) private var context

    @Query(sort: \PlannedMeal.plannedFor) private var planned: [PlannedMeal]
    @Query(sort: \Recipe.name) private var recipes: [Recipe]

    @State private var picking: (day: Date, meal: MealType)?

    /// Today plus six. A plan is a week you are shopping for, not a calendar.
    private var week: [Date] {
        let start = Calendar.current.startOfDay(for: .now)
        return (0..<7).compactMap { Calendar.current.date(byAdding: .day, value: $0, to: start) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if recipes.isEmpty {
                    Text("Add a recipe first — the plan is built from them.")
                        .font(Theme.detail)
                        .foregroundStyle(Theme.textSecondary)
                }

                ForEach(week, id: \.self) { day in
                    daySection(day)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 40)
        }
        .sheet(item: Binding(
            get: { picking.map { PickerTarget(day: $0.day, meal: $0.meal) } },
            set: { if $0 == nil { picking = nil } }
        )) { target in
            RecipePickerView(recipes: recipes) { recipe, servings, amountGrams in
                add(recipe, servings: servings, amountGrams: amountGrams, to: target.day, meal: target.meal)
                picking = nil
            }
            .preferredColorScheme(.dark)
        }
    }

    private struct PickerTarget: Identifiable {
        let day: Date
        let meal: MealType
        var id: String { "\(DayKey.make(from: day))-\(meal.rawValue)" }
    }

    private func daySection(_ day: Date) -> some View {
        let key = DayKey.make(from: day)
        let forDay = planned.filter { $0.dayKey == key }

        return VStack(alignment: .leading, spacing: 10) {
            Text(dayLabel(day))
                .font(Theme.cardTitle)
                .foregroundStyle(Theme.accent)

            ForEach(MealType.allCases) { meal in
                let meals = forDay.filter { $0.mealType == meal }
                HStack(alignment: .top, spacing: 10) {
                    Text(meal.displayName)
                        .font(Theme.detail)
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 66, alignment: .leading)

                    if meals.isEmpty {
                        Button {
                            picking = (day: day, meal: meal)
                        } label: {
                            Text("Add")
                                .font(Theme.detail)
                                .foregroundStyle(Theme.accent.opacity(0.8))
                        }
                        .buttonStyle(.plain)
                        Spacer()
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(meals) { plannedMeal in
                                plannedRow(plannedMeal)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .padding(Theme.cardPadding)
        .background(Theme.surface, in: .rect(cornerRadius: Theme.cardRadius))
    }

    /// Remove is a trailing "x", matching how FoodView already deletes a
    /// logged entry. Spelling it out cost more width than the column has: an
    /// earlier version wrapped it mid-word, and the fixes for that either blew
    /// the card past the page margin or truncated "Logged" to "Log...".
    private func plannedRow(_ meal: PlannedMeal) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text(meal.recipeName)
                    .font(Theme.body)
                    .foregroundStyle(Theme.textPrimary)

                // scaledNutrition, not the raw snapshot: the snapshot is per
                // serving, and this row is a whole meal.
                if let nutrition = meal.scaledNutrition {
                    Text("\(Int(nutrition.calories)) kcal")
                        .font(Theme.detail)
                        .foregroundStyle(Theme.textSecondary)
                }

                if meal.isLogged {
                    Label("Logged", systemImage: "checkmark")
                        .font(Theme.detail)
                        .foregroundStyle(Theme.textSecondary)
                } else if meal.snapshotNutrition != nil {
                    Button("Log it") { log(meal) }
                        .font(Theme.detail.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                        .buttonStyle(.plain)
                }
            }

            Spacer(minLength: 4)

            Button {
                remove(meal)
            } label: {
                Text("x")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain)
        }
    }

    private func add(_ recipe: Recipe, servings: Double, amountGrams: Double?, to day: Date, meal: MealType) {
        // Plan at midday, not midnight — a meal planned for "Tuesday" that
        // lands at 00:00 reads as Monday night in a log sorted by time.
        let at = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: day) ?? day
        context.insert(PlannedMeal(recipe: recipe, mealType: meal, plannedFor: at, servings: servings, amountGrams: amountGrams))
        try? context.save()
    }

    private func remove(_ meal: PlannedMeal) {
        context.delete(meal)
        try? context.save()
    }

    /// Writes the log entry, then records that it happened.
    ///
    /// The order matters: `loggedFoodEntryID` is the only thing stopping a
    /// second tap logging the same dinner twice, so it is set from the entry
    /// that actually exists rather than optimistically beforehand.
    private func log(_ meal: PlannedMeal) {
        guard !meal.isLogged, let entry = meal.makeFoodEntry() else { return }
        context.insert(entry)
        meal.loggedFoodEntryID = entry.id
        try? context.save()
        WidgetCenter.shared.reloadAllTimelines()
        WatchSyncReceiver.shared?.pushRecentFoodsSnapshot()
    }
}

// MARK: - Recipe picker

struct RecipePickerView: View {
    let recipes: [Recipe]
    let onPick: (Recipe, Double, Double?) -> Void  // recipe, servings, amountGrams

    @Environment(\.dismiss) private var dismiss
    @AppStorage("servingUnit") private var servingUnitRaw = ServingUnit.grams.rawValue

    @State private var servings: Double = 1
    @State private var amountText = ""
    @State private var selected: Recipe?

    private var servingUnit: ServingUnit { ServingUnit(rawValue: servingUnitRaw) ?? .grams }

    var body: some View {
        NavigationStack {
            // Gated on `nutritionPerGram`, not `totalWeightGrams` alone: a
            // recipe can have a total weight set but no macros ever entered,
            // in which case there is no per-gram nutrition to scale by and
            // the legacy servings path is the only one that can work.
            if let selected, selected.nutritionPerGram != nil {
                gramEntry(for: selected)
            } else {
                recipeList
            }
        }
    }

    private var recipeList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.cardSpacing) {
                HStack {
                    Text("Servings")
                        .font(Theme.body)
                    Spacer()
                    Stepper(
                        value: $servings,
                        in: 0.5...12,
                        step: 0.5
                    ) {
                        Text(servingsLabel(servings))
                            .font(Theme.body)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .fixedSize()
                }
                .padding(Theme.cardPadding)
                .background(Theme.surface, in: .rect(cornerRadius: Theme.cardRadius))

                ForEach(recipes) { recipe in
                    Button {
                        if recipe.nutritionPerGram != nil {
                            selected = recipe
                        } else {
                            onPick(recipe, servings, nil)
                            dismiss()
                        }
                    } label: {
                        HStack {
                            Text(recipe.name)
                                .font(Theme.body)
                                .foregroundStyle(Theme.textPrimary)
                            Spacer()
                            if let nutrition = recipe.nutritionPerServing {
                                Text("\(Int(nutrition.calories * servings)) kcal")
                                    .font(Theme.detail)
                                    .foregroundStyle(Theme.textSecondary)
                            }
                        }
                        .padding(Theme.cardPadding)
                        .background(Theme.surface, in: .rect(cornerRadius: Theme.cardRadius))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .liftScreen()
        .background(Theme.background)
        .navigationTitle("Pick a recipe")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
        }
    }

    // MARK: Gram entry

    /// Mirrors `FoodSearchView.amountEntry(for:)`: an amount typed in the
    /// person's preferred `ServingUnit`, converted to grams via
    /// `ServingUnit.toGrams(_:)` before it ever reaches `onPick`/`PlannedMeal`.
    private func gramEntry(for recipe: Recipe) -> some View {
        let enteredAmount = Double(amountText)
        let grams = enteredAmount.map { servingUnit.toGrams($0) }
        let preview = grams.flatMap { recipe.nutritionPerGram?.scaled(by: $0) }

        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(recipe.name)
                    .font(Theme.cardTitle)
                    .foregroundStyle(Theme.accent)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Amount")
                        .font(Theme.sectionLabel)
                        .foregroundStyle(Theme.accent)

                    HStack {
                        TextField("0", text: $amountText)
                            .keyboardType(.decimalPad)
                            .font(Theme.body)
                            .foregroundStyle(Theme.textPrimary)
                        Text(servingUnit.abbreviation)
                            .font(Theme.body)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .padding(Theme.cardPadding)
                    .background(Theme.background, in: .rect(cornerRadius: Theme.chipRadius))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Theme.cardPadding)
                .background(Theme.surface, in: .rect(cornerRadius: Theme.cardRadius))

                if let preview {
                    previewCard(preview)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .liftScreen()
        .background(Theme.background)
        .navigationTitle(recipe.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Back") {
                    selected = nil
                    amountText = ""
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Log") {
                    guard let enteredAmount, enteredAmount > 0 else { return }
                    onPick(recipe, servings, servingUnit.toGrams(enteredAmount))
                    dismiss()
                }
                .disabled(!(enteredAmount.map { $0 > 0 } ?? false))
            }
        }
    }

    private func previewCard(_ nutrition: NutritionFacts) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(Int(nutrition.calories)) kcal")
                .font(Theme.figure)
                .foregroundStyle(Theme.textPrimary)
            HStack(spacing: 10) {
                Text("P \(Int(nutrition.proteinG))")
                Text("C \(Int(nutrition.carbsG))")
                Text("F \(Int(nutrition.fatG))")
                if let fiber = nutrition.fiberG {
                    Text("Fib \(Int(fiber))")
                }
            }
            .font(Theme.detail)
            .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.cardPadding)
        .background(Theme.surface, in: .rect(cornerRadius: Theme.cardRadius))
    }
}

// MARK: - Shopping

struct ShoppingListView: View {
    @Environment(\.modelContext) private var context

    @Query private var planned: [PlannedMeal]
    @Query private var recipes: [Recipe]
    @Query private var checks: [ShoppingListCheck]

    var body: some View {
        let lines = ShoppingList.build(
            from: upcoming,
            recipes: Dictionary(uniqueKeysWithValues: recipes.map { ($0.id, $0) })
        )
        let checkedKeys = Set(checks.map(\.itemKey))

        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if lines.isEmpty {
                    Text("Nothing planned for the next week, so there is nothing to buy yet.")
                        .font(Theme.detail)
                        .foregroundStyle(Theme.textSecondary)
                } else {
                    ForEach(lines) { line in
                        row(line, isChecked: checkedKeys.contains(line.key))
                    }

                    if !checkedKeys.isEmpty {
                        Button("Clear ticks") { clearChecks() }
                            .font(Theme.detail)
                            .foregroundStyle(Theme.textSecondary)
                            .buttonStyle(.plain)
                            .padding(.top, 8)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 40)
        }
    }

    /// Only what is still ahead. A list that keeps yesterday's shopping on it
    /// stops being a list you trust.
    private var upcoming: [PlannedMeal] {
        let today = DayKey.today
        return planned.filter { $0.dayKey >= today }
    }

    private func row(_ line: ShoppingListLine, isChecked: Bool) -> some View {
        Button {
            toggle(line.key, isChecked: isChecked)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: isChecked ? "checkmark.square.fill" : "square")
                    .font(.system(size: 18))
                    .foregroundStyle(isChecked ? Theme.accent : Theme.hairline)

                VStack(alignment: .leading, spacing: 3) {
                    Text(line.displayName)
                        .font(Theme.body)
                        .foregroundStyle(isChecked ? Theme.textSecondary : Theme.textPrimary)
                        .strikethrough(isChecked, color: Theme.textSecondary)

                    if !line.amounts.isEmpty {
                        Text(amountsLabel(line.amounts))
                            .font(Theme.detail)
                            .foregroundStyle(Theme.textSecondary)
                    }

                    // Ingredients that never parsed. Shown verbatim so nothing
                    // silently drops off the list you shop from.
                    ForEach(line.unparsed, id: \.self) { raw in
                        Text(raw)
                            .font(Theme.detail)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                Spacer()
            }
            .padding(Theme.cardPadding)
            .background(Theme.surface, in: .rect(cornerRadius: Theme.cardRadius))
        }
        .buttonStyle(.plain)
    }

    private func toggle(_ key: String, isChecked: Bool) {
        if isChecked {
            for check in checks where check.itemKey == key { context.delete(check) }
        } else {
            context.insert(ShoppingListCheck(itemKey: key))
        }
        try? context.save()
    }

    private func clearChecks() {
        for check in checks { context.delete(check) }
        try? context.save()
    }

    /// Counts print bare — "2", not "2 x banana".
    private func amountsLabel(_ amounts: [String: Double]) -> String {
        amounts
            .sorted { $0.key < $1.key }
            .map { unit, value in
                unit == IngredientParser.countUnit
                    ? trimmed(value)
                    : "\(trimmed(value)) \(unit)"
            }
            .joined(separator: " + ")
    }
}

// MARK: - Shared formatting

func servingsLabel(_ value: Double) -> String {
    let n = trimmed(value)
    return value == 1 ? "1 serving" : "\(n) servings"
}

func trimmed(_ value: Double) -> String {
    value == value.rounded() ? String(Int(value)) : String(format: "%g", value)
}

func dayLabel(_ date: Date) -> String {
    if Calendar.current.isDateInToday(date) { return "Today" }
    if Calendar.current.isDateInTomorrow(date) { return "Tomorrow" }
    let f = DateFormatter()
    f.dateFormat = "EEEE"
    return f.string(from: date)
}
