import SwiftData
import SwiftUI

struct OutdoorActivityListView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \OutdoorActivity.startedAt, order: .reverse) private var activities: [OutdoorActivity]
    @AppStorage("distanceUnit") private var unitRaw = DistanceUnit.miles.rawValue
    @State private var startingActivityType: OutdoorActivityType?
    @State private var justFinishedActivity: OutdoorActivity?

    private var unit: DistanceUnit { DistanceUnit(rawValue: unitRaw) ?? .miles }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button("Start Run") { startingActivityType = .run }
                    Button("Start Hike") { startingActivityType = .hike }
                }
                Section("History") {
                    ForEach(activities) { activity in
                        NavigationLink {
                            OutdoorActivityReviewView(activity: activity)
                        } label: {
                            row(for: activity)
                        }
                    }
                    .onDelete { offsets in
                        for index in offsets { context.delete(activities[index]) }
                        try? context.save()
                    }
                }
            }
            .navigationTitle("Outdoor")
            .fullScreenCover(item: $startingActivityType) { type in
                NavigationStack {
                    OutdoorActivityRecordingView(activityType: type) { activity in
                        startingActivityType = nil
                        justFinishedActivity = activity
                    }
                }
            }
            .fullScreenCover(item: $justFinishedActivity) { activity in
                NavigationStack {
                    OutdoorActivityReviewView(activity: activity)
                }
            }
        }
    }

    private func row(for activity: OutdoorActivity) -> some View {
        VStack(alignment: .leading) {
            Text(activity.activityType.displayName).font(.headline)
            Text(String(format: "%.2f %@", unit.fromMeters(activity.distanceMeters), unit.abbreviation))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
