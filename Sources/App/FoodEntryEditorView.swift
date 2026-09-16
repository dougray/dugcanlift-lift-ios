import SwiftUI
import SwiftData
import WidgetKit
import LiftCore

/// Edits a food entry already in the log, in place: same id, same day, same
/// `loggedAt`. The rules — how an amount rescales the macros, which entries let
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
    let entry: FoodEntry

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    @State private var edit: FoodEntryEdit

    /// Which field has the keyboard. The decimal pad has no return key, and
    /// without a way to put it away it covers the macros the amount rescales.
    private enum Field: Hashable { case name, amount, macro(FoodEntryEdit.Macro) }
    @FocusState private var focus: Field?

    init(entry: FoodEntry, preferredUnit: ServingUnit) {
        self.entry = entry
        _edit = State(initialValue: FoodEntryEdit(entry: entry, preferredUnit: preferredUnit))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    nameSection
                    amountSection
                    mealSection
                    macrosSection

                    if let problem = edit.problem {
                        Text(problem)
                            .font(Theme.detail)
                            .foregroundStyle(Theme.accent)
                    }

                    if entry.healthKitUUID != nil {
                        Text("This entry was saved to Apple Health by an earlier install. Changes here stay in LIFT — edit it in the Health app too if it should match.")
                            .font(Theme.detail)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
            .scrollDismissesKeyboard(.interactively)
            .liftScreen()
            .background(Theme.background)
            .navigationTitle("Edit food")
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
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.name)
                    .font(Theme.cardTitle)
                    .foregroundStyle(Theme.accent)
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
        if edit.isManual {
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

    // MARK: Pieces

    private func macroField(_ macro: FoodEntryEdit.Macro) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(macro.label) (\(macro.unit))")
                .font(Theme.detail)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            TextField("—", text: Binding(
                get: { edit.text(for: macro) },
                set: { edit.setText($0, for: macro) }
            ))
            .keyboardType(.decimalPad)
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
                .foregroundStyle(Theme.accent)
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
        guard edit.apply(to: entry) else { return }
        try? context.save()
        WidgetCenter.shared.reloadAllTimelines()
        WatchSyncReceiver.shared?.pushRecentFoodsSnapshot()
        dismiss()
    }
}
