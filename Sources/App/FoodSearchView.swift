import SwiftData
import SwiftUI
import WidgetKit
import LiftCore
import LiftReference

/// Search the bundled food.db and log a chosen amount straight onto today's
/// log — the actual "log a new food" flow, built for the first time here.
///
/// Two stages in one view, the same shape as `RecipePickerView`/
/// `ExercisePickerView`: a searchable list, then a picked-item detail. Gram-based
/// from the start, per the spec's explicit decision — there is no serving-count
/// stepper here, only a plain amount in the person's preferred unit
/// (`ServingUnit`, Settings > Serving size), converted to the canonical gram
/// amount `FoodEntry.amountGrams` stores.
struct FoodSearchView: View {
    let mealType: MealType
    var onLogged: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @AppStorage("servingUnit") private var servingUnitRaw = ServingUnit.grams.rawValue

    @State private var query = ""
    @State private var results: [FoodRecord] = []
    @State private var loadFailed = false
    @State private var selected: FoodRecord?
    @State private var amountText = ""

    private var servingUnit: ServingUnit { ServingUnit(rawValue: servingUnitRaw) ?? .grams }

    var body: some View {
        NavigationStack {
            if let selected {
                amountEntry(for: selected)
            } else {
                searchList
            }
        }
    }

    // MARK: Search

    private var searchList: some View {
        Group {
            if loadFailed {
                ContentUnavailableView(
                    "Food data unavailable",
                    systemImage: "exclamationmark.triangle",
                    description: Text("food.db is missing from the app bundle.")
                )
            } else if results.isEmpty && query.trimmingCharacters(in: .whitespaces).count >= 2 {
                ContentUnavailableView.search(text: query)
            } else {
                List(results) { record in
                    Button {
                        selected = record
                    } label: {
                        row(record)
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Log Food")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Search foods")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
        }
        // Re-runs whenever query changes; the sleep debounces keystrokes, and
        // SwiftUI cancels the previous task automatically — a real
        // reference-DB query on every keystroke is wasted work for a search
        // field where most keystrokes are superseded within milliseconds by
        // the next one.
        .task(id: query) {
            await search()
        }
    }

    private func row(_ record: FoodRecord) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(record.name)
                .font(Theme.body)
                .foregroundStyle(Theme.textPrimary)
            if let brand = record.brand, !brand.isEmpty {
                Text(brand)
                    .font(Theme.detail)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func search() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else {
            results = []
            loadFailed = false
            return
        }

        try? await Task.sleep(for: .milliseconds(200))
        guard !Task.isCancelled else { return }

        do {
            let found = try await ReferenceDatabase.shared.searchFoods(trimmed)
            guard !Task.isCancelled else { return }
            results = found
            loadFailed = false
        } catch {
            results = []
            loadFailed = true
        }
    }

    // MARK: Amount entry

    private func amountEntry(for record: FoodRecord) -> some View {
        let enteredAmount = Double(amountText)
        let grams = enteredAmount.map { servingUnit.toGrams($0) }
        let preview = grams.map { record.nutrition(grams: $0) }

        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(record.name)
                        .font(Theme.cardTitle)
                        .foregroundStyle(Theme.accent)
                    if let brand = record.brand, !brand.isEmpty {
                        Text(brand)
                            .font(Theme.detail)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }

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
                .liftCardBackground()

                if let preview {
                    previewCard(preview)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .liftScreen()
        .background(Theme.background)
        .navigationTitle("Log Food")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Back") {
                    self.selected = nil
                    amountText = ""
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Log") { log(record) }
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
            // Saturated fat, sugar and sodium when the database has them —
            // `FoodRecord.nutrition(grams:)` fills all three, and the entry
            // logged below snapshots them with the rest.
            if let details = NutrientDetailsDisplay.entryLine(nutrition) {
                Text(details)
                    .font(Theme.detail)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.cardPadding)
        .liftCardBackground()
    }

    private func log(_ record: FoodRecord) {
        guard let enteredAmount = Double(amountText), enteredAmount > 0 else { return }
        let grams = servingUnit.toGrams(enteredAmount)
        let entry = FoodEntry(
            foodRefID: record.id,
            name: record.name,
            brand: record.brand,
            quantity: enteredAmount,
            servingUnit: servingUnit.abbreviation,
            amountGrams: grams,
            nutrition: record.nutrition(grams: grams),
            mealType: mealType
        )
        context.insert(entry)
        try? context.save()
        WidgetCenter.shared.reloadAllTimelines()
        WatchSyncReceiver.shared?.pushRecentFoodsSnapshot()
        onLogged()
        dismiss()
    }
}
