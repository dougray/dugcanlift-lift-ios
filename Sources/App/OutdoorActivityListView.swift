import SwiftData
import SwiftUI

struct OutdoorActivityListView: View {
    @Query(sort: \OutdoorActivity.startedAt, order: .reverse) private var activities: [OutdoorActivity]
    @AppStorage("distanceUnit") private var unitRaw = DistanceUnit.miles.rawValue
    @State private var startingActivityType: OutdoorActivityType?

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
                }
            }
            .navigationTitle("Outdoor")
            .fullScreenCover(item: $startingActivityType) { type in
                NavigationStack {
                    OutdoorActivityRecordingView(activityType: type)
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
