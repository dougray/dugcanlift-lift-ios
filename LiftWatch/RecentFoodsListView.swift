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
                List(items, id: \.foodRefID) { item in
                    NavigationLink(item.displayName) {
                        FoodAmountEntryView(item: item)
                    }
                }
            } else {
                Text("Log a food on your phone to see it here.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding()
            }
        }
        .navigationTitle("Log Food")
    }
}
