import LiftKit
import SwiftUI

/// A short, static list, matching `ExercisePickerView`'s own reasoning
/// (`WorkoutView.swift`): scrolling a long list on a wrist is not a feature.
/// `WorkoutSessionModel.recentFoodsSnapshot` already caps the item count —
/// this view never re-sorts or re-filters it.
struct RecentFoodsListView: View {
    @EnvironmentObject private var session: WorkoutSessionModel

    var body: some View {
        Group {
            if let items = session.recentFoodsSnapshot?.items, !items.isEmpty {
                List(items, id: \.self) { item in
                    NavigationLink(item.displayName) {
                        FoodAmountEntryView(item: item)
                    }
                }
            } else {
                // Not just "log it on your phone" -- that's a dead end for
                // the exact user the bundled library (`FoodSearchView`,
                // "All Foods") was added for: someone with no paired iPhone
                // at all. Point at the row that actually works for them,
                // while still mentioning the phone for those who have one.
                Text("No recent foods from your phone yet. Try All Foods to search the built-in library.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding()
            }
        }
        .navigationTitle("Log Food")
    }
}
