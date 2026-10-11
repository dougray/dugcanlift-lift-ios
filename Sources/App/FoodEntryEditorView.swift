import SwiftUI
import SwiftData
import WidgetKit
import LiftCore

/// Edits a food entry already in the log, in place: same id, same day, same
/// `loggedAt` — or, opened with `init(newNamed:...)` from food search's "Add
/// food by hand", adds one with its macros typed per 100 g. The rules — how an amount rescales the macros, which entries let
/// the macros be typed, what blank means — are `FoodEntryEdit`'s, so they are
/// tested without a view.
///
/// **Apple Health.** LIFT for iOS does not write food to Health: nothing in
/// `HealthKitManager` saves a dietary sample, so an entry logged on this phone
/// never has a `healthKitUUID`. One can still arrive with one, from a backup, and
/// HealthKit lets an app change or delete only samples it saved itself, which
/// this build cannot confirm about a sample another install wrote. So an edit
/// never touches Health and leaves `healthKitUUID` as it was, and the editor
/// says so in words for an entry that carries one, rather than implying Health
/// was updated.
struct FoodEntryEditorView: View {
    /// nil for a food being added by hand.
    let entry: FoodEntry?
    /// After a new entry is saved, before this sheet goes away.
    private var onSaved: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var edit: FoodEntryEdit

    /// Which field has the keyboard. The decimal pad has no return key, and
    /// without a way to put it away it covers the macros the amount rescales.
    private enum Field: Hashable { case name, amount, macro(FoodEntryEdit.Macro) }
    @FocusState private var focus: Field?

    /// Collapsed on open: saturated fat, sugar and sodium are tracked, never
    /// targeted, and most edits are an amount or a meal.
    @State private var showingMoreNutrients = false

    init(entry: FoodEntry, preferredUnit: ServingUnit) {
        self.entry = entry
        _edit = State(initialValue: FoodEntryEdit(entry: entry, preferredUnit: preferredUnit))
    }

    /// A food that is not in the database, added by hand: name (from the search
    /// query, when there was one), meal, amount, and macros per 100 g.
    init(newNamed name: String, mealType: MealType, preferredUnit: ServingUnit,
         onSaved: @escaping () -> Void = {}) {
        self.entry = nil
        self.onSaved = onSaved
        _edit = State(initialValue: FoodEntryEdit(newNamed: name, mealType: mealType,
                                                  preferredUnit: preferredUnit))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    nameSection
                    amountSection
                    mealSection
                    macrosSection
                    moreNutrientsSection
                    totalsSection

                    if let problem = edit.problem {
                        Text(problem)
                            .font(Theme.detail)
                            .foregroundStyle(Theme.accentText)
                    }

                    if entry?.healthKitUUID != nil {
                        Text("This entry was saved to Apple Health by an earlier install. Changes here stay in LIFT — edit it in the Health app too if it should match.")
                            .font(Theme.detail)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .readableContentWidth()
            }
            .scrollDismissesKeyboard(.interactively)
            .liftScreen()
            .background(Theme.background)
            .navigationTitle(edit.isNew ? "Add food" : "Edit food")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(edit.result == nil)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { focus = nil }
                }
            }
        }
    }

    // MARK: Sections

    @ViewBuilder
    private var nameSection: some View {
        if edit.isManual {
            card("Name") {
                TextField("Food name", text: $edit.name)
                    .textInputAutocapitalization(.sentences)
                    .focused($focus, equals: .name)
                    .font(Theme.body)
                    .padding(Theme.cardPadding / 2)
                    .background(Theme.background, in: .rect(cornerRadius: Theme.chipRadius))
            }
        } else if let entry {
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.name)
                    .font(Theme.cardTitle)
                    .foregroundStyle(Theme.accentText)
                if let brand = entry.brand, !brand.isEmpty {
                    Text(brand)
                        .font(Theme.detail)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
    }

    private var amountSection: some View {
        card("Amount") {
            HStack {
                TextField("0", text: $edit.amountText)
                    .keyboardType(.decimalPad)
                    .focused($focus, equals: .amount)
                    .accessibilityLabel("Amount, \(edit.amountUnitLabel)")
                    .font(Theme.body)
                    .foregroundStyle(Theme.textPrimary)
                    .disabled(!edit.canChangeAmount)
                Text(edit.amountUnitLabel)
                    .font(Theme.body)
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(Theme.cardPadding)
            .background(Theme.background, in: .rect(cornerRadius: Theme.chipRadius))

            if !edit.canChangeAmount {
                Text("Logged as zero, so there is nothing to scale from. The amount stays as it is.")
                    .font(Theme.detail)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private var mealSection: some View {
        card("Meal") {
            Picker("Meal", selection: $edit.mealType) {
                ForEach(MealType.allCases) { meal in
                    Text(meal.displayName).tag(meal)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    @ViewBuilder
    private var macrosSection: some View {
        if edit.isNew {
            card("Macros per 100\u{00A0}g", hint: "As the label reads them per 100\u{00A0}g; the amount above works out the totals. Fibre can be left blank — blank stays unknown, not zero.") {
                // Two to a row: "Protein (g/100g)" does not fit four across.
                macroField(.calories)
                fieldGrid([.protein, .carbs, .fat, .fiber])
            }
        } else if edit.isManual {
            card("Macros", hint: "Totals for the amount above. Fibre can be left blank — blank stays unknown, not zero.") {
                // Calories on its own row and the four gram figures under it,
                // as the recipe editor lays them out.
                macroField(.calories)
                HStack(spacing: 10) {
                    macroField(.protein)
                    macroField(.carbs)
                    macroField(.fat)
                    macroField(.fiber)
                }
            }
        } else if let nutrition = edit.nutrition {
            card("Macros", hint: "From the food's own data, scaled to the amount above.") {
                // Truncated with Int(), as the log row and FoodSearchView's
                // preview show them, so the same entry reads the same here.
                Text("\(Int(nutrition.calories)) kcal")
                    .font(Theme.figure)
                    .foregroundStyle(Theme.textPrimary)
                HStack(spacing: 14) {
                    macroFigure("Protein", nutrition.proteinG)
                    macroFigure("Carbs", nutrition.carbsG)
                    macroFigure("Fat", nutrition.fatG)
                    if let fiber = nutrition.fiberG { macroFigure("Fibre", fiber) }
                }
            }
        }
    }

    /// Saturated fat, sugar and sodium. Typed for a manual entry, like the
    /// macros; read-only for a food with a source, and shown only when that
    /// source recorded them.
    private var moreNutrientsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { showingMoreNutrients.toggle() }
            } label: {
                HStack {
                    Text("More nutrients")
                        .font(Theme.sectionLabel)
                        .foregroundStyle(Theme.accentText)
                    Spacer()
                    if !showingMoreNutrients, let summary = detailsSummary {
                        Text(summary)
                            .font(Theme.detail)
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                    }
                    Image(systemName: "chevron.down")
                        .scaledFont(size: 13, weight: .semibold)
                        .foregroundStyle(Theme.textSecondary)
                        .rotationEffect(.degrees(showingMoreNutrients ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(showingMoreNutrients ? "Expanded" : "Collapsed")

            if showingMoreNutrients {
                if edit.isNew {
                    Text("Saturated fat, sugar and sodium, per 100\u{00A0}g like the macros. No goals — blank stays unknown, not zero.")
                        .font(Theme.detail)
                        .foregroundStyle(Theme.textSecondary)
                    fieldGrid([.saturatedFat, .sugar, .sodium])
                } else if edit.isManual {
                    Text("Saturated fat, sugar and sodium, as totals for the amount above. No goals — blank stays unknown, not zero.")
                        .font(Theme.detail)
                        .foregroundStyle(Theme.textSecondary)
                    HStack(alignment: .top, spacing: 10) {
                        macroField(.saturatedFat)
                        macroField(.sugar)
                        macroField(.sodium)
                    }
                } else if let nutrition = edit.nutrition,
                          NutrientDetailsDisplay.entryLine(nutrition) != nil {
                    Text("From the food's own data, scaled to the amount above. No goals.")
                        .font(Theme.detail)
                        .foregroundStyle(Theme.textSecondary)
                    HStack(spacing: 14) {
                        ForEach(NutrientDetailsDisplay.Nutrient.allCases) { nutrient in
                            if let value = nutrient.value(in: nutrition) {
                                detailFigure(nutrient.label, nutrient.formatted(value))
                            }
                        }
                    }
                } else {
                    Text("This food's source did not record saturated fat, sugar or sodium.")
                        .font(Theme.detail)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.cardPadding)
        .liftCardBackground()
    }

    /// A new entry's fields are per 100 g, so the totals that will be logged —
    /// for the amount typed — are shown on their own, the way food search
    /// previews a database food. Nothing until there is something to total.
    @ViewBuilder
    private var totalsSection: some View {
        if edit.isNew, edit.amount != nil, let nutrition = edit.nutrition {
            card("Totals for \(edit.amountText.trimmingCharacters(in: .whitespaces)) \(edit.amountUnitLabel)") {
                // Truncated with Int(), as FoodSearchView's preview and the log
                // row show them, so the entry reads the same once it is logged.
                Text("\(Int(nutrition.calories)) kcal")
                    .font(Theme.figure)
                    .foregroundStyle(Theme.textPrimary)
                HStack(spacing: 14) {
                    macroFigure("Protein", nutrition.proteinG)
                    macroFigure("Carbs", nutrition.carbsG)
                    macroFigure("Fat", nutrition.fatG)
                    if let fiber = nutrition.fiberG { macroFigure("Fibre", fiber) }
                }
                if let details = NutrientDetailsDisplay.entryLine(nutrition) {
                    Text(details)
                        .font(Theme.detail)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    /// How many of the three are known, for the collapsed header: "2 of 3".
    private var detailsSummary: String? {
        guard let nutrition = edit.nutrition else { return nil }
        let known = NutrientDetailsDisplay.Nutrient.allCases.filter { $0.value(in: nutrition) != nil }.count
        return known == 0 ? nil : "\(known) of 3 known"
    }

    // MARK: Pieces

    private func detailFigure(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(Theme.detail)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
            Text(value)
                .font(Theme.body.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
        }
    }

    /// Two fields to a row, or one at an accessibility text size, where
    /// "Protein (g/100g)" no longer fits half the width.
    private func fieldGrid(_ macros: [FoodEntryEdit.Macro]) -> some View {
        let columns = dynamicTypeSize.isAccessibilitySize ? 1 : 2
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10, alignment: .top),
                                        count: columns),
                         alignment: .leading, spacing: 10) {
            ForEach(macros) { macroField($0) }
        }
    }

    private func macroField(_ macro: FoodEntryEdit.Macro) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(edit.fieldLabel(for: macro))
                .font(Theme.detail)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            TextField("—", text: Binding(
                get: { edit.text(for: macro) },
                set: { edit.setText($0, for: macro) }
            ))
            .keyboardType(.decimalPad)
            .accessibilityLabel(edit.fieldLabel(for: macro))
            .focused($focus, equals: .macro(macro))
            .font(Theme.body)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.background, in: .rect(cornerRadius: Theme.chipRadius))
            .disabled(!edit.canEditMacros)
        }
    }

    private func macroFigure(_ label: String, _ grams: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(Theme.detail)
                .foregroundStyle(Theme.textSecondary)
            Text("\(Int(grams)) g")
                .font(Theme.body.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
        }
    }

    private func card<Content: View>(
        _ title: String,
        hint: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(Theme.sectionLabel)
                .foregroundStyle(Theme.accentText)
            if let hint {
                Text(hint)
                    .font(Theme.detail)
                    .foregroundStyle(Theme.textSecondary)
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.cardPadding)
        .liftCardBackground()
    }

    // MARK: Saving

    private func save() {
        if let entry {
            guard edit.apply(to: entry) else { return }
        } else {
            guard let new = edit.makeEntry() else { return }
            context.insert(new)
        }
        try? context.save()
        WidgetCenter.shared.reloadAllTimelines()
        WatchSyncReceiver.shared?.pushRecentFoodsSnapshot()
        if entry == nil { onSaved() }
        dismiss()
    }
}
