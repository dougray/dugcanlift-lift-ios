import SwiftUI
import SwiftData
import WidgetKit

/// Meal-grouped food log. Search is unavailable until food.db is built —
/// see Tools/build_reference.py and SETUP.md.
struct FoodView: View {
    @Environment(\.modelContext) private var context

    @Query private var entries: [FoodEntry]

    /// The whole log, newest first — the source for Recent below.
    @Query(sort: \FoodEntry.loggedAt, order: .reverse) private var allEntries: [FoodEntry]

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
    private var recent: [FoodEntry] {
        var seen = Set<String>()
        var result: [FoodEntry] = []
        for entry in allEntries {
            let key = entry.displayName.trimmingCharacters(in: .whitespaces).lowercased()
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            result.append(entry)
            if result.count == 10 { break }
        }
        return result
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ForEach(MealType.allCases) { meal in
                    let mealEntries = entries.filter { $0.mealType == meal }
                    section(meal, entries: mealEntries)
                }

                recentSection
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 40)
        }
        .liftScreen()
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
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.displayName)
                                .font(Theme.body)
                                .foregroundStyle(Theme.textPrimary)
                            Text(macroLine(entry))
                                .font(Theme.detail)
                                .foregroundStyle(Theme.textSecondary)
                        }
                        Spacer()
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
            nutrition: entry.nutrition,
            mealType: MealType.forHour(Calendar.current.component(.hour, from: now)),
            loggedAt: now
        )
        context.insert(copy)
        try? context.save()
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// "240 kcal - P 8 - F 2 - C 46 - Fib 2"
    private func macroLine(_ entry: FoodEntry) -> String {
        let n = entry.nutrition
        var parts = ["\(Int(n.calories)) kcal",
                     "P \(Int(n.proteinG))",
                     "F \(Int(n.fatG))",
                     "C \(Int(n.carbsG))"]
        if let fiber = n.fiberG { parts.append("Fib \(Int(fiber))") }
        return parts.joined(separator: " - ")
    }
}
