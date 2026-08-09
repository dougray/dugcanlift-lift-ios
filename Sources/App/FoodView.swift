import SwiftUI
import SwiftData

/// Meal-grouped food log. Search is unavailable until food.db is built —
/// see Tools/build_reference.py and SETUP.md.
struct FoodView: View {
    @Environment(\.modelContext) private var context

    @Query private var entries: [FoodEntry]

    init() {
        let key = DayKey.today
        _entries = Query(
            filter: #Predicate<FoodEntry> { $0.dayKey == key },
            sort: \FoodEntry.loggedAt
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ForEach(MealType.allCases) { meal in
                    let mealEntries = entries.filter { $0.mealType == meal }
                    section(meal, entries: mealEntries)
                }
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
