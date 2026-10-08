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
    @Environment(\.pageWidth) private var pageWidth

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

    /// Shared with Road Food, which ranks against the same number.
    private var remaining: RemainingMacros? {
        RemainingMacros.forDay(goalIsSet: goalIsSet, goalCalories: goalCalories,
                               goalProteinG: goalProtein, eaten: totals)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.cardSpacing) {
                Text("LIFT")
                    .scaledFont(size: 30, weight: .heavy)
                    .foregroundStyle(AppColor.accentText)
                    .padding(.top, 8)

                Text("Today")
                    .liftFont(.cardTitle)
                    .foregroundStyle(AppColor.accentText)

                // Two columns of cards once each can be a phone's width.
                AdaptiveColumns(columns: AdaptiveLayout.columns(
                    for: AdaptiveLayout.contentWidth(forPage: pageWidth))) {
                    if goalIsSet {
                        LiftCard {
                            VStack(alignment: .leading, spacing: 14) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(calorieHeadline)
                                        .liftFont(.figure)
                                        .foregroundStyle(Theme.textPrimary)
                                    Text("\(Int(totals.calories)) of \(Int(goalCalories))")
                                        .liftFont(.detail)
                                        .foregroundStyle(Theme.textSecondary)
                                }

                                AppMacroProgressRow(label: "Protein", current: totals.proteinG,
                                                 goal: goalProtein, unit: "g")
                                AppMacroProgressRow(label: "Fat", current: totals.fatG,
                                                 goal: goalFat, unit: "g")
                                AppMacroProgressRow(label: "Carbs", current: totals.carbsG,
                                                 goal: goalCarbs, unit: "g")
                                AppMacroProgressRow(label: "Fiber", current: totals.fiberG ?? 0,
                                                 goal: goalFiber, unit: "g")
                            }
                        }
                    } else {
                        LiftCard {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("No goal set yet.")
                                    .scaledFont(size: 17, weight: .bold)
                                    .foregroundStyle(Theme.textPrimary)
                                Text("Work out your daily calories and macros to start tracking against them.")
                                    .liftFont(.body)
                                    .foregroundStyle(Theme.textSecondary)
                                // A filled pill, as the browser build renders a
                                // primary action. Bare accent text reads as a link
                                // and is easy to miss next to the web's button.
                                LiftButton("Set my goal") { showingCalculator = true }
                                    .padding(.top, 8)
                            }
                        }
                    }

                    AppCard(title: "Steps") {
                        VStack(alignment: .leading, spacing: 10) {
                            AppMacroProgressRow(label: "Today", current: todaySteps,
                                             goal: goalSteps, unit: "steps")
                            // HealthKit never says whether reading steps was
                            // refused, so no steps after LIFT has asked may be
                            // either. Say where they come from and where to
                            // allow it -- never ask again from here.
                            if todaySteps == 0 && health.isAvailable && health.hasAskedForAuthorization {
                                Text("No steps from Apple Health yet. If LIFT isn't allowed to read them, turn Steps on in Settings › Privacy & Security › Health › LIFT.")
                                    .liftFont(.detail)
                                    .foregroundStyle(Theme.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            HStack(spacing: 20) {
                                Button("Edit goal") {
                                    stepGoalInput = String(Int(goalSteps))
                                    showingStepGoalEditor = true
                                }
                                if todaySteps == 0 && health.isAvailable && health.hasAskedForAuthorization {
                                    Button("Open Settings") { HealthSettingsLink.open() }
                                }
                            }
                            .scaledFont(size: 13, weight: .semibold)
                            .foregroundStyle(AppColor.accentText)
                        }
                    }

                    AppCard(title: "Training") {
                        if let day, day.totalSetCount > 0 {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(day.name.isEmpty ? day.focus.displayName : day.name)
                                    .scaledFont(size: 18, weight: .semibold)
                                    .foregroundStyle(Theme.textPrimary)
                                Text("\(day.exercises.count) exercises · \(day.summary(unit: unit))")
                                    .liftFont(.detail)
                                    .foregroundStyle(Theme.textSecondary)
                            }
                        } else {
                            Text("Nothing logged yet")
                                .liftFont(.body)
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }

                    AppCard(title: "Fuel so far today") {
                        VStack(spacing: 9) {
                            AppStatRow(label: "Calories", value: "\(Int(totals.calories)) kcal")
                            AppStatRow(label: "Protein", value: "\(Int(totals.proteinG)) g")
                            AppStatRow(label: "Carbs", value: "\(Int(totals.carbsG)) g")
                            AppStatRow(label: "Fat", value: "\(Int(totals.fatG)) g")
                            AppStatRow(label: "Fiber", value: "\(Int(totals.fiberG ?? 0)) g")
                            // Saturated fat, sugar and sodium, when any food today
                            // recorded them. Totals only, never against a goal.
                            NutrientTotalRows(totals: NutrientDetailsDisplay.dayTotals(todaysFood.map(\.nutrition)))
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 40)
            .adaptivePageWidth()
        }
        .appScreen()
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
        // First run only. After any answer, Home reads what Health gives and
        // says so quietly rather than asking again (HealthAuthorization).
        try? await health.authorize(.automatic)
        todaySteps = (try? await health.todaysStepCount()) ?? 0
    }

    private var calorieHeadline: String {
        if totals.calories == 0 { return "Nothing logged" }
        return remaining?.calorieHeadline ?? ""
    }
}
