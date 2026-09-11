import LiftKit
import SwiftUI

/// Digital Crown entry, mirroring `LogSetView`'s weight stepper exactly —
/// the user is dialing in an amount by feel, not typing a number.
struct FoodAmountEntryView: View {
    let item: RecentFoodsSnapshot.Item

    @EnvironmentObject private var session: WorkoutSessionModel
    @Environment(\.dismiss) private var dismiss

    @State private var amount: Double = 100
    @State private var meal: FoodLogMeal = .forHour(Calendar.current.component(.hour, from: .now))

    private var unit: ServingUnit { session.servingUnit }
    private var step: Double { unit == .grams ? 5 : 0.5 }
    private var maxAmount: Double { unit == .grams ? 2000 : 70 }

    var body: some View {
        List {
            Section {
                Stepper(value: $amount, in: 0...maxAmount, step: step) {
                    LabeledValue("Amount", "\(formattedAmount) \(unit.abbreviation)")
                }
                .focusable()
                .digitalCrownRotation($amount, from: 0, through: maxAmount, by: step)

                Button(unit == .grams ? "Switch to oz" : "Switch to g") {
                    // `2000 g` and `70 oz` aren't exact equivalents (2000 g is
                    // ~70.55 oz) — clamp so a value near either cap can't land
                    // outside the Stepper/crown range for the new unit.
                    let grams = unit.toGrams(amount)
                    session.servingUnit = unit == .grams ? .ounces : .grams
                    amount = min(session.servingUnit.fromGrams(grams), maxAmount)
                }
            }

            Section {
                Picker("Meal", selection: $meal) {
                    ForEach(FoodLogMeal.allCases, id: \.self) { option in
                        Text(option.displayName).tag(option)
                    }
                }
            }

            Section {
                Button("Log") {
                    session.enqueueFoodLogged(
                        foodRefID: item.foodRefID,
                        amountGrams: unit.toGrams(amount),
                        meal: meal
                    )
                    // Also retain it locally. An item cached before macros
                    // were added has none, and an entry with unknown macros
                    // is skipped rather than exported as a zero-calorie meal.
                    if let food = item.watchFood {
                        session.recordLocally(food: food, grams: unit.toGrams(amount), meal: meal)
                    }
                    dismiss()
                }
            }
        }
        .navigationTitle(item.displayName)
        .onAppear(perform: seedFromLastAmount)
    }

    /// Whole numbers print without a decimal; ounces otherwise show one
    /// decimal place, matching the phone app's own `FoodEntryDisplay`
    /// formatting convention.
    private var formattedAmount: String {
        amount.rounded() == amount ? String(Int(amount)) : String(format: "%.1f", amount)
    }

    private func seedFromLastAmount() {
        guard let lastGrams = item.lastAmountGrams else { return }
        // The wire contract doesn't bound `lastAmountGrams` — clamp the same
        // way the unit-switch button does, so a large phone-side value can't
        // seed the Stepper/crown outside its own range.
        amount = min(unit.fromGrams(lastGrams), maxAmount)
    }
}
