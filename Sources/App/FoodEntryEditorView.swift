import SwiftUI
import SwiftData
import WidgetKit
import LiftCore

/// Edits a food entry already in the log, in place: same id, same day, same
/// `loggedAt` — or, opened with `init(newNamed:...)` from food search's "Add
/// food by hand", adds one with its macros typed per 100 g. The rules — how
/// an amount rescales the macros, which entries let the macros be typed, what
/// blank means — are `FoodEntryEdit`'s, so they are tested without a view.
///
/// **A barcode.** Opened with a `barcode`, "Add food" logs the entry with
/// `foodRefID` `barcode:<code>` *and* remembers the food against that code, per
/// 100 g as typed, so the next scan finds it. Opened with
/// `init(remembering:...)`, it edits only what LIFT remembers — name and
/// per-100 g values, no meal, no amount — and never touches a `FoodEntry`;
/// "Forget this barcode" removes the remembered food, and anything already
/// logged keeps its own name and numbers.
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
    /// After a new entry is saved, or a remembered food saved or forgotten,
    /// before this sheet goes away.
    private var onSaved: () -> Void = {}
    /// The code of the remembered food being edited; nil in every other mode.
    private var rememberedCode: String?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled

    @State private var edit: FoodEntryEdit

    /// Which field has the keyboard. The decimal pad has no return key, and
    /// without a way to put it away it covers the macros the amount rescales.
    private enum Field: Hashable { case name, amount, macro(FoodEntryEdit.Macro) }
    @FocusState private var focus: Field?

    /// Collapsed on open: saturated fat, sugar and sodium are tracked, never
    /// targeted, and most edits are an amount or a meal.
    @State private var showingMoreNutrients = false
    @State private var confirmingForget = false

    init(entry: FoodEntry, preferredUnit: ServingUnit) {
        self.entry = entry
        _edit = State(initialValue: FoodEntryEdit(entry: entry, preferredUnit: preferredUnit))
    }

    /// A food that is not in the database, added by hand: name (from the search
    /// query, when there was one), meal, amount, and macros per 100 g.
    /// With a `barcode` (normalised), saving also remembers the food against it.
    init(newNamed name: String, mealType: MealType, preferredUnit: ServingUnit,
         barcode: String? = nil, onSaved: @escaping () -> Void = {}) {
        self.entry = nil
        self.onSaved = onSaved
        var edit = FoodEntryEdit(newNamed: name, mealType: mealType, preferredUnit: preferredUnit)
        edit.barcode = barcode
        _edit = State(initialValue: edit)
    }

    /// What LIFT remembers about a barcode: name and per-100 g values only.
    init(remembering food: RememberedFood, preferredUnit: ServingUnit,
         onSaved: @escaping () -> Void = {}) {
        self.entry = nil
        self.onSaved = onSaved
        self.rememberedCode = food.code
        _edit = State(initialValue: FoodEntryEdit(remembering: food, preferredUnit: preferredUnit))
    }

    private var title: String {
        if edit.editsRememberedFoodOnly { return RememberedFoodWords.editTitle }
        return edit.isNew ? "Add food" : "Edit food"
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        nameSection
                        if !edit.editsRememberedFoodOnly {
                            amountSection
                            mealSection
                        }
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

                        if rememberedCode != nil {
                            Button(RememberedFoodWords.forgetButton, role: .destructive) {
                                confirmingForget = true
                            }
                            .font(Theme.body)
                            .frame(minHeight: 44)
                            .padding(.top, 4)
                            .forgetBarcodeConfirmation(isPresented: $confirmingForget) { forget() }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .readableContentWidth()
                }
                .scrollDismissesKeyboard(.interactively)
                .liftScreen()
                .background(Theme.background)
                .navigationTitle(title)
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
                // A new food starts typing where the gap is: the name when the
                // search gave none, calories when it did. Never under
                // VoiceOver, which places its own focus, and never over a
                // field the person has already chosen. Not for a remembered
                // food either: like editing a logged entry, there is no gap
                // to fill, so nothing takes the keyboard uninvited.
                .task {
                    guard edit.isNew, !voiceOverEnabled else { return }
                    // Decided before the wait, so typing into the name during
                    // it cannot send focus to calories mid-word.
                    let target: Field = edit.name.trimmingCharacters(in: .whitespaces).isEmpty
                        ? .name : .macro(.calories)
                    // A sheet still presenting drops focus, so wait it out.
                    // Cancelled (sheet closed) or a field already chosen:
                    // do nothing.
                    guard (try? await Task.sleep(for: .milliseconds(450))) != nil,
                          focus == nil else { return }
                    focus = target
                    // Calories sits low enough for the keyboard to cover it,
                    // so once the keyboard is up it is scrolled into view.
                    guard target != .name,
                          (try? await Task.sleep(for: .milliseconds(600))) != nil,
                          focus == target else { return }
                    withAnimation { proxy.scrollTo(FoodEntryEdit.Macro.calories, anchor: .center) }
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
                if let code = barcodeShown {
                    Text("Barcode \(code)")
                        .font(Theme.detail)
                        .foregroundStyle(Theme.textSecondary)
                        .accessibilityLabel("Barcode")
                        // Digit by digit, as it is printed, not as one number.
                        .accessibilityValue(Text(code).speechSpellsOutCharacters())
                }
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

    /// Read-only: the code a new entry was scanned against, or the one whose
    /// remembered food is being edited.
    private var barcodeShown: String? {
        rememberedCode ?? (edit.isNew ? edit.barcode : nil)
    }

    /// The field says "Amount, grams" itself, so the title and the unit beside
    /// it are hidden from VoiceOver rather than read a second and third time.
    private var amountSection: some View {
        card("Amount", titleIsFieldLabel: true) {
            HStack {
                TextField("0", text: $edit.amountText)
                    .keyboardType(.decimalPad)
                    .focused($focus, equals: .amount)
                    .accessibilityLabel(edit.spokenAmountLabel)
                    .font(Theme.body)
                    .foregroundStyle(Theme.textPrimary)
                    .disabled(!edit.canChangeAmount)
                Text(edit.amountUnitLabel)
                    .font(Theme.body)
                    .foregroundStyle(Theme.textSecondary)
                    .accessibilityHidden(true)
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
        if edit.isNew || edit.editsRememberedFoodOnly {
            card("Macros per 100\u{00A0}g", hint: edit.isNew
                 ? "As the label reads them per 100\u{00A0}g; the amount above works out the totals. Fibre can be left blank — blank stays unknown, not zero."
                 : "As the label reads them per 100\u{00A0}g. Fibre can be left blank — blank stays unknown, not zero.") {
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
                if edit.isNew || edit.editsRememberedFoodOnly {
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

    /// Two fields to a row, or one from xLarge text up, where "Saturated fat
    /// (g/100g)" no longer fits half the width of a 375 pt phone and the
    /// "per 100 g" — the whole point of the label — would be cut off.
    private func fieldGrid(_ macros: [FoodEntryEdit.Macro]) -> some View {
        let columns = dynamicTypeSize >= .xLarge ? 1 : 2
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
                // The field carries it, in words; read once, not twice.
                .accessibilityHidden(true)
            TextField("—", text: Binding(
                get: { edit.text(for: macro) },
                set: { edit.setText($0, for: macro) }
            ))
            .keyboardType(.decimalPad)
            .accessibilityLabel(edit.spokenFieldLabel(for: macro))
            .focused($focus, equals: .macro(macro))
            .font(Theme.body)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.background, in: .rect(cornerRadius: Theme.chipRadius))
            .disabled(!edit.canEditMacros)
        }
        .id(macro)
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
        titleIsFieldLabel: Bool = false,
        hint: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(Theme.sectionLabel)
                .foregroundStyle(Theme.accentText)
                .accessibilityHidden(titleIsFieldLabel)
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
        if let code = rememberedCode {
            saveRemembered(code: code)
            return
        }
        if let entry {
            guard edit.apply(to: entry) else { return }
        } else {
            guard let new = edit.makeEntry() else { return }
            context.insert(new)
            if let code = edit.barcode {
                // A savable new entry always has its per-100 g values; if it
                // somehow did not, the entry is still logged and nothing is
                // remembered rather than a zero being invented.
                if let per100g = edit.per100g {
                    RememberedFoods.remember(code: code, name: new.name, per100g: per100g, in: context)
                } else {
                    assertionFailure("a new entry with a result has per-100 g values")
                }
            }
        }
        try? context.save()
        WidgetCenter.shared.reloadAllTimelines()
        WatchSyncReceiver.shared?.pushRecentFoodsSnapshot()
        if entry == nil { onSaved() }
        dismiss()
    }

    /// Only the remembered food. No `FoodEntry` is written, so there is no
    /// widget or watch snapshot to refresh: both read logged entries, which
    /// keep their own numbers.
    private func saveRemembered(code: String) {
        guard let result = edit.result, let per100g = edit.per100g else { return }
        RememberedFoods.remember(code: code, name: result.name, per100g: per100g, in: context)
        onSaved()
        dismiss()
    }

    private func forget() {
        guard let code = rememberedCode else { return }
        RememberedFoods.forget(code: code, in: context)
        onSaved()
        dismiss()
    }
}
