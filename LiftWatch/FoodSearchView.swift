import LiftKit
import SwiftUI

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
                Stepper(value: $grams, in: 5...1000, step: 5) {
                    Text("\(Int(grams)) g")
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
                    session.recordLocally(food: food, grams: grams, meal: meal)
                    dismiss()
                }
            }
        }
        .navigationTitle(food.name)
    }
}
