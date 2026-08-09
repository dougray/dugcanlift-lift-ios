import SwiftUI
import SwiftData

/// Goals live in AppStorage rather than SwiftData — they're single-valued
/// preferences, not history, and the widget can read them via the shared suite.
struct MacroGoals {
    @AppStorage("goalCalories") static var calories = 1748.0
    @AppStorage("goalProtein")  static var protein = 160.0
    @AppStorage("goalFat")      static var fat = 49.0
    @AppStorage("goalCarbs")    static var carbs = 167.0
    @AppStorage("goalFiber")    static var fiber = 24.0
}

struct HomeView: View {
    @AppStorage("weightUnit") private var unitRaw = WeightUnit.pounds.rawValue
    @AppStorage("goalCalories") private var goalCalories = 1748.0
    @AppStorage("goalProtein") private var goalProtein = 160.0
    @AppStorage("goalFat") private var goalFat = 49.0
    @AppStorage("goalCarbs") private var goalCarbs = 167.0
    @AppStorage("goalFiber") private var goalFiber = 24.0

    @Query private var todaysFood: [FoodEntry]
    @Query private var todaysTraining: [WorkoutDay]

    init() {
        let key = DayKey.today
        _todaysFood = Query(filter: #Predicate<FoodEntry> { $0.dayKey == key })
        _todaysTraining = Query(filter: #Predicate<WorkoutDay> { $0.dayKey == key })
    }

    private var unit: WeightUnit { WeightUnit(rawValue: unitRaw) ?? .pounds }
    private var totals: NutritionFacts { todaysFood.totalNutrition }
    private var day: WorkoutDay? { todaysTraining.first }

    private var calorieDelta: Double { totals.calories - goalCalories }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.cardSpacing) {
                Text("LIFT")
                    .font(.system(size: 30, weight: .heavy))
                    .foregroundStyle(Theme.accent)
                    .padding(.top, 8)

                Text("Today")
                    .font(Theme.cardTitle)
                    .foregroundStyle(Theme.accent)

                LiftCard {
                    VStack(alignment: .leading, spacing: 14) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(calorieHeadline)
                                .font(Theme.figure)
                                .foregroundStyle(Theme.textPrimary)
                            Text("\(Int(totals.calories)) of \(Int(goalCalories))")
                                .font(Theme.detail)
                                .foregroundStyle(Theme.textSecondary)
                        }

                        MacroProgressRow(label: "Protein", current: totals.proteinG,
                                         goal: goalProtein, unit: "g")
                        MacroProgressRow(label: "Fat", current: totals.fatG,
                                         goal: goalFat, unit: "g")
                        MacroProgressRow(label: "Carbs", current: totals.carbsG,
                                         goal: goalCarbs, unit: "g")
                        MacroProgressRow(label: "Fiber", current: totals.fiberG ?? 0,
                                         goal: goalFiber, unit: "g")
                    }
                }

                LiftCard(title: "Training") {
                    if let day, day.totalSetCount > 0 {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(day.name.isEmpty ? day.focus.displayName : day.name)
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(Theme.textPrimary)
                            Text("\(day.exercises.count) exercises · \(day.summary(unit: unit))")
                                .font(Theme.detail)
                                .foregroundStyle(Theme.textSecondary)
                        }
                    } else {
                        Text("Nothing logged yet")
                            .font(Theme.body)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }

                LiftCard(title: "Fuel so far today") {
                    VStack(spacing: 9) {
                        StatRow(label: "Calories", value: "\(Int(totals.calories)) kcal")
                        StatRow(label: "Protein", value: "\(Int(totals.proteinG)) g")
                        StatRow(label: "Carbs", value: "\(Int(totals.carbsG)) g")
                        StatRow(label: "Fat", value: "\(Int(totals.fatG)) g")
                        StatRow(label: "Fiber", value: "\(Int(totals.fiberG ?? 0)) g")
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 40)
        }
        .liftScreen()
    }

    private var calorieHeadline: String {
        if totals.calories == 0 { return "Nothing logged" }
        let delta = abs(Int(calorieDelta))
        return calorieDelta >= 0 ? "\(delta) kcal over" : "\(delta) kcal left"
    }
}
