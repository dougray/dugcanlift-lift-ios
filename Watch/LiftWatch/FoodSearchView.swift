import LiftKit
import SwiftUI
import LiftSync
import WatchKit

/// Search the bundled USDA library. This is what a watch that has never been
/// paired to a LIFT iPhone logs from — `RecentFoodsListView` shows only what
/// the phone pushed, and for a PWA user the phone never pushes anything.
struct FoodSearchView: View {
    @EnvironmentObject private var session: WorkoutSessionModel
    @State private var query = ""

    var body: some View {
        List {
            TextField("Search foods", text: $query)

            ForEach(WatchFoodLibrary.shared.search(query), id: \.self) { food in
                NavigationLink(food.name) {
                    LibraryFoodAmountView(food: food)
                }
            }
        }
        .navigationTitle("All Foods")
    }
}

/// Amount and meal for a library food. Deliberately not reusing
/// `FoodAmountEntryView`: that one takes a `RecentFoodsSnapshot.Item` and
/// sends a `foodRefID` to the phone, neither of which a library food has.
struct LibraryFoodAmountView: View {
    let food: WatchFood

    @EnvironmentObject private var session: WorkoutSessionModel
    @Environment(\.dismiss) private var dismiss
    @State private var grams: Double = 100
    @State private var meal: FoodLogMeal = .forHour(Calendar.current.component(.hour, from: .now))

    var body: some View {
        List {
            Section {
                // 2000 g, the same ceiling the recents screen has always used —
                // see `AmountLimits`. This stopped at 1000 g, so a 1.5 kg cook-up
                // was loggable only if the food happened to come from the phone.
                // The Crown too, as the other amount screens have: 500 g by
                // the Stepper alone was 80 taps.
                Stepper(value: $grams, in: AmountLimits.minGrams...AmountLimits.maxGrams, step: 5) {
                    LabeledValue("Amount", "\(Int(grams)) g")
                }
                .focusable()
                .digitalCrownRotation($grams, from: AmountLimits.minGrams,
                                      through: AmountLimits.maxGrams, by: 5)
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
                    session.recordLocally(food: food, grams: grams, meal: meal)
                    WKInterfaceDevice.current().play(.success)
                    dismiss()
                }
            }
        }
        .navigationTitle(food.name)
    }
}
