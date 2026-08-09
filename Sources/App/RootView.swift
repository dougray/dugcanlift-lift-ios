import SwiftUI
import SwiftData
import WidgetKit

/// Temporary shell. The real information architecture comes from the existing
/// LIFT app — this exists so the project builds and so the App Group plumbing
/// can be verified before any real UI is written.
struct RootView: View {
    var body: some View {
        TabView {
            DiagnosticsView()
                .tabItem { Label("Today", systemImage: "square.grid.2x2") }

            WorkoutsView()
                .tabItem { Label("Workouts", systemImage: "figure.strengthtraining.traditional") }

            Text("Food")
                .tabItem { Label("Food", systemImage: "fork.knife") }

            Text("Settings")
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
    }
}

/// Smoke test for the architecture: writes through SwiftData into the App Group
/// container, then asks WidgetKit to reload. If the widget updates, the shared
/// container, the schema and the target membership are all correct.
struct DiagnosticsView: View {
    @Environment(\.modelContext) private var context

    @Query(sort: \FoodEntry.loggedAt, order: .reverse)
    private var foodEntries: [FoodEntry]

    @Query(sort: \WorkoutSession.startedAt, order: .reverse)
    private var workouts: [WorkoutSession]

    private var todaysFood: [FoodEntry] {
        let key = DayKey.today
        return foodEntries.filter { $0.dayKey == key }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Store") {
                    LabeledContent("App group", value: LiftStore.appGroupID)
                    LabeledContent("Location", value: storeLocation)
                        .font(.caption)
                }

                Section("Today — \(DayKey.today)") {
                    LabeledContent("Calories",
                                   value: todaysFood.totalNutrition.calories,
                                   format: .number.precision(.fractionLength(0)))
                    LabeledContent("Protein",
                                   value: todaysFood.totalNutrition.proteinG,
                                   format: .number.precision(.fractionLength(1)))
                    LabeledContent("Food entries", value: "\(todaysFood.count)")
                    LabeledContent("Workouts", value: "\(workouts.count)")
                }

                Section("Smoke test") {
                    Button("Add sample meal", systemImage: "plus.circle") {
                        addSampleMeal()
                    }
                    Button("Add sample workout", systemImage: "plus.circle") {
                        addSampleWorkout()
                    }
                    Button("Clear all", systemImage: "trash", role: .destructive) {
                        clearAll()
                    }
                }

                if !todaysFood.isEmpty {
                    Section("Log") {
                        ForEach(todaysFood) { entry in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.displayName)
                                Text("\(entry.mealType.displayName) · \(entry.nutrition.calories, format: .number.precision(.fractionLength(0))) kcal")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Lift")
        }
    }

    private var storeLocation: String {
        LiftStore.shared.configurations.first?.url.path ?? "unknown"
    }

    private func addSampleMeal() {
        let entry = FoodEntry(
            foodRefID: "usda:174608",
            name: "Chicken breast, grilled",
            quantity: 150,
            servingUnit: "g",
            servingGrams: 150,
            nutrition: NutritionFacts(calories: 247, proteinG: 46.4, carbsG: 0, fatG: 5.4),
            mealType: .lunch
        )
        context.insert(entry)
        save()
    }

    private func addSampleWorkout() {
        let session = WorkoutSession(title: "Push Day")
        let bench = ExerciseEntry(exerciseRefID: "wger:73", name: "Bench Press", orderIndex: 0)
        bench.sets = [
            SetEntry(orderIndex: 0, reps: 8, weightKg: 60),
            SetEntry(orderIndex: 1, reps: 8, weightKg: 62.5)
        ]
        session.exercises = [bench]
        session.endedAt = .now.addingTimeInterval(3600)
        context.insert(session)
        save()
    }

    private func clearAll() {
        for entry in foodEntries { context.delete(entry) }
        for workout in workouts { context.delete(workout) }
        save()
    }

    /// SwiftData does not notify the widget process. Every mutation that
    /// changes widget content must reload timelines explicitly.
    private func save() {
        try? context.save()
        WidgetCenter.shared.reloadAllTimelines()
    }
}
