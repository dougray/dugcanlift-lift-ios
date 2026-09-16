import SwiftUI
import SwiftData
import LiftCore

/// Goals live in AppStorage rather than SwiftData — they're single-valued
/// preferences, not history, and the widget can read them via the shared suite.
struct MacroGoals {
    @AppStorage("goalCalories") static var calories = 1748.0
    @AppStorage("goalProtein")  static var protein = 160.0
    @AppStorage("goalFat")      static var fat = 49.0
    @AppStorage("goalCarbs")    static var carbs = 167.0
    @AppStorage("goalFiber")    static var fiber = 24.0
    /// Distinguishes "user saved a goal" from the placeholder defaults above.
    @AppStorage("goalIsSet")    static var isSet = false
}

struct HomeView: View {
    @AppStorage("weightUnit") private var unitRaw = WeightUnit.pounds.rawValue
    @AppStorage("goalCalories") private var goalCalories = 1748.0
    @AppStorage("goalProtein") private var goalProtein = 160.0
    @AppStorage("goalFat") private var goalFat = 49.0
    @AppStorage("goalCarbs") private var goalCarbs = 167.0
    @AppStorage("goalFiber") private var goalFiber = 24.0
    @AppStorage("goalIsSet") private var goalIsSet = false
    /// 10,000 is a starting recommendation, not a requirement — editable via
    /// the Steps card so someone can build up toward it.
    @AppStorage("goalSteps") private var goalSteps = 10_000.0

    @State private var showingCalculator = false
    @State private var health = HealthKitManager.shared
    @State private var todaySteps: Double = 0
    @State private var showingStepGoalEditor = false
    @State private var stepGoalInput = ""

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

                if goalIsSet {
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
                } else {
                    LiftCard {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("No goal set yet.")
                                .font(.system(size: 17, weight: .bold))
                                .foregroundStyle(Theme.textPrimary)
                            Text("Work out your daily calories and macros to start tracking against them.")
                                .font(Theme.body)
                                .foregroundStyle(Theme.textSecondary)
                            // A filled pill, as the browser build renders a
                            // primary action. Bare accent text reads as a link
                            // and is easy to miss next to the web's button.
                            LiftButton("Set my goal") { showingCalculator = true }
                                .padding(.top, 8)
                        }
                    }
                }

                LiftCard(title: "Steps") {
                    VStack(alignment: .leading, spacing: 10) {
                        MacroProgressRow(label: "Today", current: todaySteps,
                                         goal: goalSteps, unit: "steps")
                        Button("Edit goal") {
                            stepGoalInput = String(Int(goalSteps))
                            showingStepGoalEditor = true
                        }
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.accent)
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
                        // Saturated fat, sugar and sodium, when any food today
                        // recorded them. Totals only, never against a goal.
                        NutrientTotalRows(totals: NutrientDetailsDisplay.dayTotals(todaysFood.map(\.nutrition)))
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 40)
        }
        .liftScreen()
        .sheet(isPresented: $showingCalculator) {
            CalculatorView()
        }
        .alert("Step Goal", isPresented: $showingStepGoalEditor) {
            TextField("Steps per day", text: $stepGoalInput)
                .keyboardType(.numberPad)
            Button("Save") {
                if let value = Double(stepGoalInput), value > 0 {
                    goalSteps = value
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .task { await loadSteps() }
    }

    private func loadSteps() async {
        guard health.isAvailable else { return }
        try? await health.requestAuthorization()
        todaySteps = (try? await health.todaysStepCount()) ?? 0
    }

    private var calorieHeadline: String {
        if totals.calories == 0 { return "Nothing logged" }
        let delta = abs(Int(calorieDelta))
        return calorieDelta >= 0 ? "\(delta) kcal over" : "\(delta) kcal left"
    }
}
