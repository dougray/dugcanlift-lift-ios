import SwiftUI
import SwiftData
import WidgetKit
import LiftCore

/// Meal-grouped food log. `food.db` ships (see SETUP.md) and
/// `FoodSearchView` — presented here as a sheet — is the search-and-log UI,
/// gram-based from the start. This view also supports editing a logged entry
/// (tap its row — `FoodEntryEditorView`), re-logging a past entry, or deleting
/// one.
struct FoodView: View {
    @Environment(\.modelContext) private var context

    @Query private var entries: [FoodEntry]

    @State private var showingSearch = false
    @State private var editing: FoodEntry?

    /// Same pattern as `WeightUnit`/`DistanceUnit`/`FoodSearchView`: a live,
    /// current-device display preference, not part of any stored record.
    @AppStorage("servingUnit") private var servingUnitRaw = ServingUnit.grams.rawValue
    private var servingUnit: ServingUnit { ServingUnit(rawValue: servingUnitRaw) ?? .grams }

    init() {
        let key = DayKey.today
        _entries = Query(
            filter: #Predicate<FoodEntry> { $0.dayKey == key },
            sort: \FoodEntry.loggedAt
        )
    }

    /// Most people eat the same handful of things. Anything logged before can
    /// be re-logged in one tap, which removes most of the manual entry pain.
    ///
    /// Matches the Android build's Recent list, deliberately — same count, same
    /// de-duplication by name, same one-tap behaviour.
    ///
    /// This does a fresh, non-reactive fetch on every call rather than using
    /// `@Query` directly — it stays live today only because `entries` above
    /// *is* an `@Query` scoped to today's `dayKey`, and every mutation this
    /// view can currently trigger (logging, re-logging) always lands in
    /// today's `dayKey`, so SwiftUI's `entries`-driven re-render always
    /// re-evaluates this too. A future write path that can log to a
    /// *different* day (e.g. a backdated entry, or a watch-originated log)
    /// would not trigger that re-render, and "Recent" could go stale until
    /// something else causes one. Not a bug today — just an implicit
    /// coupling worth knowing about before adding such a path.
    private var recent: [FoodEntry] {
        RecentFoodsQuery.recent(context: context, limit: 10)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Button {
                    showingSearch = true
                } label: {
                    Label("Log food", systemImage: "plus")
                        .font(Theme.body.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Theme.cardPadding)
                        .liftCardBackground()
                }
                .buttonStyle(.plain)

                ForEach(MealType.allCases) { meal in
                    let mealEntries = entries.filter { $0.mealType == meal }
                    section(meal, entries: mealEntries)
                }

                NutrientTotalsSection(foods: entries)

                recentSection
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 40)
        }
        .liftScreen()
        .sheet(isPresented: $showingSearch) {
            FoodSearchView(mealType: MealType.forHour(Calendar.current.component(.hour, from: .now)))
                .liftAppearance()
        }
        .sheet(item: $editing) { entry in
            FoodEntryEditorView(entry: entry, preferredUnit: servingUnit)
                .liftAppearance()
        }
    }

    private func section(_ meal: MealType, entries mealEntries: [FoodEntry]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(meal.displayName)
                    .font(Theme.cardTitle)
                    .foregroundStyle(Theme.accent)
                Spacer()
                Text("\(Int(mealEntries.totalNutrition.calories)) kcal")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Theme.textSecondary)
            }

            if mealEntries.isEmpty {
                Text("Nothing logged")
                    .font(Theme.detail)
                    .foregroundStyle(Theme.textSecondary)
            } else {
                ForEach(mealEntries) { entry in
                    HStack(alignment: .top) {
                        Button {
                            editing = entry
                        } label: {
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.displayName)
                                        .font(Theme.body)
                                        .foregroundStyle(Theme.textPrimary)
                                    Text(macroLine(entry))
                                        .font(Theme.detail)
                                        .foregroundStyle(Theme.textSecondary)
                                    if let details = NutrientDetailsDisplay.entryLine(entry.nutrition) {
                                        Text(details)
                                            .font(Theme.detail)
                                            .foregroundStyle(Theme.textSecondary)
                                    }
                                }
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Edit the amount, meal or macros")
                        Button {
                            context.delete(entry)
                            try? context.save()
                        } label: {
                            Text("x")
                                .font(.system(size: 17, weight: .bold))
                                .foregroundStyle(Theme.accent)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var recentSection: some View {
        if !recent.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Recent")
                    .font(Theme.cardTitle)
                    .foregroundStyle(Theme.accent)

                Text("Tap to log it again, into the meal that fits the time of day.")
                    .font(Theme.detail)
                    .foregroundStyle(Theme.textSecondary)

                ForEach(recent) { entry in
                    Button {
                        logAgain(entry)
                    } label: {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.displayName)
                                    .font(Theme.body)
                                    .foregroundStyle(Theme.textPrimary)
                                Text(macroLine(entry))
                                    .font(Theme.detail)
                                    .foregroundStyle(Theme.textSecondary)
                            }
                            Spacer()
                            Image(systemName: "arrow.counterclockwise")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Theme.accent)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 8)
        }
    }

    /// Copies a previous entry into now.
    ///
    /// A copy, not a reference: `FoodEntry` snapshots its nutrition at log
    /// time, and re-logging must not tie today's breakfast to the row that
    /// happened to be its template. Deleting the original later must leave this
    /// one untouched.
    private func logAgain(_ entry: FoodEntry) {
        let now = Date.now
        let copy = FoodEntry(
            foodRefID: entry.foodRefID,
            name: entry.name,
            brand: entry.brand,
            quantity: entry.quantity,
            servingUnit: entry.servingUnit,
            servingGrams: entry.servingGrams,
            amountGrams: entry.amountGrams,
            nutrition: entry.nutrition,
            mealType: MealType.forHour(Calendar.current.component(.hour, from: now)),
            loggedAt: now
        )
        context.insert(copy)
        try? context.save()
        WidgetCenter.shared.reloadAllTimelines()
        WatchSyncReceiver.shared?.pushRecentFoodsSnapshot()
    }

    /// "140 g - 240 kcal - P 8 - F 2 - C 46 - Fib 2"
    private func macroLine(_ entry: FoodEntry) -> String {
        let n = entry.nutrition
        var parts = [FoodEntryDisplay.amountText(for: entry, preferredUnit: servingUnit),
                     "\(Int(n.calories)) kcal",
                     "P \(Int(n.proteinG))",
                     "F \(Int(n.fatG))",
                     "C \(Int(n.carbsG))"]
        if let fiber = n.fiberG { parts.append("Fib \(Int(fiber))") }
        return parts.joined(separator: " - ")
    }
}

/// Pure formatting logic for a `FoodEntry`'s amount/serving text, factored
/// out of `FoodView` so it's directly unit-testable without standing up a
/// view (`FoodView` itself needs a live `ModelContext`/`Query` environment).
///
/// `amountGrams` is the canonical gram amount for entries logged via the
/// gram-based search-and-log flow (Task 4) or successfully backfilled by the
/// migration (Task 3). Display always converts it to whichever `ServingUnit`
/// is *currently* selected in Settings — that's a live, current-device
/// preference, not part of the historical record, so it's applied regardless
/// of which unit was active when the entry was originally logged.
///
/// Entries where `amountGrams` is `nil` (legacy entries the migration
/// couldn't backfill, e.g. no `servingGrams` to convert from) keep showing
/// the pre-existing `quantity`/`servingUnit` text, completely unaffected by
/// the `ServingUnit` preference — this is the one branch the whole
/// migration strategy depends on being correct.
enum FoodEntryDisplay {
    static func amountText(for entry: FoodEntry, preferredUnit: ServingUnit) -> String {
        guard let amountGrams = entry.amountGrams else {
            return "\(formatAmount(entry.quantity)) \(entry.servingUnit)"
        }
        let converted = preferredUnit.fromGrams(amountGrams)
        return "\(formatAmount(converted)) \(preferredUnit.abbreviation)"
    }

    /// Whole numbers print without a decimal ("140 g"); anything else gets
    /// one decimal place ("4.9 oz") so a gram amount converted to ounces
    /// doesn't collapse to a misleadingly precise-looking integer.
    private static func formatAmount(_ value: Double) -> String {
        if value.rounded() == value {
            return String(Int(value))
        }
        return String(format: "%.1f", value)
    }
}

/// Today's saturated fat, sugar and sodium, each over only the foods that
/// recorded it — shown on Food and Home wherever fibre is. No bars and no
/// goals: these are tracked, never targeted. A partial total says how many
/// foods it covers, because it is a floor rather than a day. Nothing at all
/// when no food today recorded any of the three.
struct NutrientTotalsSection: View {
    let foods: [FoodEntry]

    var body: some View {
        let totals = NutrientDetailsDisplay.dayTotals(foods.map(\.nutrition))
        if !totals.isEmpty {
            // Laid out like a meal section above it, not a card: Food's log is
            // sections on the page, and a lone card here would read as a
            // different kind of thing.
            VStack(alignment: .leading, spacing: 12) {
                Text("Also tracked today")
                    .font(Theme.cardTitle)
                    .foregroundStyle(Theme.accent)
                NutrientTotalRows(totals: totals)
            }
        }
    }
}

/// The rows alone, for a card that already has a title.
struct NutrientTotalRows: View {
    let totals: [NutrientDetailsDisplay.Total]

    var body: some View {
        VStack(spacing: 9) {
            ForEach(totals) { total in
                VStack(alignment: .leading, spacing: 1) {
                    StatRow(label: total.nutrient.label, value: total.value)
                    if let coverage = total.coverage {
                        Text(coverage)
                            .font(Theme.detail)
                            .foregroundStyle(Theme.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}
