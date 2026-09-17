import SwiftData
import SwiftUI
import LiftCore

/// Full outdoor-activity history. Reached via "See all" from Train's Outdoor
/// section, which is also where starting a new run/hike lives — pushed onto
/// Train's own NavigationStack rather than wrapping its own.
struct OutdoorActivityListView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \OutdoorActivity.startedAt, order: .reverse) private var activities: [OutdoorActivity]
    @AppStorage("distanceUnit") private var unitRaw = DistanceUnit.miles.rawValue

    private var unit: DistanceUnit { DistanceUnit(rawValue: unitRaw) ?? .miles }

    var body: some View {
        List {
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
        .readableListMargins()
        .navigationTitle("Outdoor")
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
