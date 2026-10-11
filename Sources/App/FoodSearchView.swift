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
///
/// A food the database does not have is added by hand: "Add food by hand" sits
/// above the results, always, and a search that finds nothing offers to add
/// what was typed. Both open `FoodEntryEditorView` in its new-entry mode —
/// macros per 100 g, as LIFT web's form takes them — whose rules are
/// `FoodEntryEdit`'s, and logging it closes this sheet as logging a database
/// food does.
///
/// The amount step serves a `LoggableFood`: a library record, or a food the
/// person remembered against a barcode. A remembered food says so under its
/// name and offers Edit and Forget; nothing else about the step differs.
struct FoodSearchView: View {
    let mealType: MealType
    var onLogged: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @AppStorage("servingUnit") private var servingUnitRaw = ServingUnit.grams.rawValue

    @State private var query = ""
    @State private var results: [FoodRecord] = []
    @State private var loadFailed = false
    /// True from a keystroke until its search has answered, so "No Results"
    /// (and its button) appears only once a search has really found nothing,
    /// not for the 200 ms debounce before every one.
    @State private var searching = false
    @State private var selected: LoggableFood?
    @State private var amountText = ""
    /// The one sheet food search presents at a time.
    @State private var sheet: Sheet?
    @State private var confirmingForget = false
    /// Set when the hand-added food was logged, so this sheet closes after the
    /// editor's own sheet has gone.
    @State private var loggedByHand = false

    private enum Sheet: Identifiable {
        /// A food typed in by hand; the name is the query, or blank.
        case byHand(name: String)
        /// The editor for a remembered food, by its code.
        case remembered(code: String)

        var id: String {
            switch self {
            case .byHand(let name): return "hand:" + name
            case .remembered(let code): return "remembered:" + code
            }
        }
    }

    private var servingUnit: ServingUnit { ServingUnit(rawValue: servingUnitRaw) ?? .grams }

    var body: some View {
        NavigationStack {
            if let selected {
                amountEntry(for: selected)
            } else {
                searchList
            }
        }
        .sheet(item: $sheet, onDismiss: {
            guard loggedByHand else { return }
            onLogged()
            dismiss()
        }) { sheet in
            switch sheet {
            case .byHand(let name):
                FoodEntryEditorView(newNamed: name, mealType: mealType,
                                    preferredUnit: servingUnit) { loggedByHand = true }
                    .liftAppearance()
            case .remembered(let code):
                if let food = RememberedFoods.find(code: code, in: context) {
                    FoodEntryEditorView(remembering: food, preferredUnit: servingUnit) {
                        refreshSelected(code: code)
                    }
                    .liftAppearance()
                }
            }
        }
    }

    // MARK: Search

    /// From the top: the search field (in the navigation bar's drawer, always
    /// shown), the action rows, then what the search found.
    private var searchList: some View {
        VStack(spacing: 0) {
            actionRows
            Rectangle()
                .fill(Theme.hairline)
                .frame(height: 1)
                .accessibilityHidden(true)
            searchResults
        }
        .navigationTitle("Log Food")
        .navigationBarTitleDisplayMode(.inline)
        // At the top and always visible. Left to itself iOS 26 puts a sheet's
        // search field at the bottom, under the results it filters.
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Search foods")
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

    /// Ways to log a food other than picking a search result, one row each,
    /// pinned under the search field whatever the results are doing. A new
    /// way in (scanning a barcode) is another row here, above "Add food by
    /// hand".
    private var actionRows: some View {
        VStack(spacing: 0) {
            actionRow("Add food by hand", systemImage: "square.and.pencil",
                      hint: "For a food that is not in the database. Macros per 100 g.") {
                addByHand()
            }
        }
        .padding(.horizontal, 16)
        .readableContentWidth()
    }

    private func actionRow(_ title: String, systemImage: String, hint: String,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(Theme.body)
                .foregroundStyle(Theme.accentText)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(hint)
    }

    @ViewBuilder
    private var searchResults: some View {
        if loadFailed {
            ContentUnavailableView {
                Label("Food data unavailable", systemImage: "exclamationmark.triangle")
            } description: {
                Text("food.db is missing from the app bundle.")
            } actions: {
                // Without the database, by hand is the only way to log,
                // so whatever was typed comes along.
                if trimmedQuery.isEmpty {
                    LiftButton("Add food by hand") { addByHand() }
                } else {
                    LiftButton("Add \u{201C}\(trimmedQuery)\u{201D} by hand") { addByHand(named: trimmedQuery) }
                }
            }
        } else if !searching && results.isEmpty && trimmedQuery.count >= 2 {
            ContentUnavailableView {
                Label("No Results for \u{201C}\(trimmedQuery)\u{201D}", systemImage: "magnifyingglass")
            } description: {
                Text("Check the spelling or try a new search.")
            } actions: {
                LiftButton("Add \u{201C}\(trimmedQuery)\u{201D} by hand") { addByHand(named: trimmedQuery) }
            }
        } else {
            List(results) { record in
                Button {
                    selected = LoggableFood(record: record)
                } label: {
                    row(record)
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
            .readableListMargins()
        }
    }

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func addByHand(named name: String = "") {
        loggedByHand = false
        sheet = .byHand(name: name)
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
            searching = false
            return
        }

        searching = true
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
        searching = false
    }

    // MARK: Amount entry

    private func amountEntry(for food: LoggableFood) -> some View {
        let enteredAmount = Double(amountText)
        let grams = enteredAmount.map { servingUnit.toGrams($0) }
        let preview = grams.map { food.nutrition(grams: $0) }

        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(food.name)
                        .font(Theme.cardTitle)
                        .foregroundStyle(Theme.accentText)
                    if let brand = food.brand, !brand.isEmpty {
                        Text(brand)
                            .font(Theme.detail)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    if let code = food.rememberedCode {
                        rememberedLines(code: code)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Amount")
                        .font(Theme.sectionLabel)
                        .foregroundStyle(Theme.accentText)

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
            .readableContentWidth()
        }
        .liftScreen()
        .keyboardDoneButton()
        .background(Theme.background)
        .navigationTitle("Log Food")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Back") { backToSearch() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Log") { log(food) }
                    .disabled(!(enteredAmount.map { $0 > 0 } ?? false))
            }
        }
    }

    /// What a remembered food adds under its name: that the figures are the
    /// person's own, and the two things they can do about it.
    private func rememberedLines(code: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(LoggableFood.rememberedLine)
                .font(Theme.detail)
                .foregroundStyle(Theme.textSecondary)
            LiftButton("Edit", isGhost: true) { sheet = .remembered(code: code) }
                .accessibilityLabel(RememberedFoodWords.editTitle)
            Button(RememberedFoodWords.forgetButton, role: .destructive) {
                confirmingForget = true
            }
            .font(Theme.body)
            .frame(minHeight: 44)
            .forgetBarcodeConfirmation(isPresented: $confirmingForget) {
                RememberedFoods.forget(code: code, in: context)
                backToSearch()
            }
        }
        .padding(.top, 4)
    }

    /// After the editor saved: show what is now remembered, or go back to
    /// search if it was forgotten from inside the editor.
    private func refreshSelected(code: String) {
        if let food = RememberedFoods.find(code: code, in: context) {
            selected = LoggableFood(remembered: food)
        } else {
            backToSearch()
        }
    }

    private func backToSearch() {
        selected = nil
        amountText = ""
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

    private func log(_ food: LoggableFood) {
        guard let enteredAmount = Double(amountText), enteredAmount > 0 else { return }
        let grams = servingUnit.toGrams(enteredAmount)
        let entry = FoodEntry(
            foodRefID: food.id,
            name: food.name,
            brand: food.brand,
            quantity: enteredAmount,
            servingUnit: servingUnit.abbreviation,
            amountGrams: grams,
            nutrition: food.nutrition(grams: grams),
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
