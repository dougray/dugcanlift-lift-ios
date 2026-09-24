import SwiftData
import SwiftUI
import LiftCore

/// Full outdoor-activity history. Reached via "See all" from Train's Outdoor
/// section, which is also where starting a new run/hike lives — pushed onto
/// Train's own NavigationStack rather than wrapping its own.
struct OutdoorActivityListView: View {
    @Query(sort: \OutdoorActivity.startedAt, order: .reverse) private var activities: [OutdoorActivity]
    @AppStorage("distanceUnit") private var unitRaw = DistanceUnit.miles.rawValue

    private var unit: DistanceUnit { DistanceUnit(rawValue: unitRaw) ?? .miles }

    var body: some View {
        List {
            ForEach(activities) { activity in
                OutdoorActivityRow(activity: activity, unit: unit)
            }
        }
        .readableListMargins()
        .navigationTitle("Outdoor")
    }
}

/// One recorded activity, with the button that deletes it.
///
/// A button rather than `.onDelete`, and that was measured: the shell is a
/// paged `TabView` (`RootView`), which takes every horizontal drag for
/// itself, so the swipe that would open a delete action never reaches this
/// list — it is pushed inside Train, where a horizontal drag pages to Cook or
/// to Routines instead. The `.onDelete` that used to be here could therefore
/// never be opened, which is why a recorded run could not be deleted. Exactly
/// the defect `RoutinesView` had, and the same answer: a button that asks
/// first, and says what the delete does not touch.
private struct OutdoorActivityRow: View {
    @Environment(\.modelContext) private var context
    let activity: OutdoorActivity
    let unit: DistanceUnit

    @State private var confirmingDelete = false
    @State private var summary = OutdoorRemoval.Summary()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            NavigationLink {
                OutdoorActivityReviewView(activity: activity)
                    .followsWindowAppearance()
            } label: {
                VStack(alignment: .leading) {
                    Text(activity.activityType.displayName).font(.headline)
                    Text(OutdoorRecords.distanceText(activity.distanceMeters, unit: unit))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Button("Delete", role: .destructive) {
                summary = OutdoorRemoval.summary(for: activity, in: context)
                confirmingDelete = true
            }
            .font(.caption.weight(.semibold))
            .buttonStyle(.borderless)
            // Both, and that was measured: `.tint` alone left the label the
            // system's bright red here, where the same two lines in
            // `RoutinesView` give rust -- a row whose other half is a
            // `NavigationLink` resolves a destructive button's colour
            // differently. Rust is the app's word for destructive everywhere
            // else, including the routine row this screen is modelled on.
            .tint(Theme.accent)
            .foregroundStyle(Theme.accent)
        }
        .deletesOutdoorActivity(activity, summary: summary, isPresented: $confirmingDelete)
    }
}

/// The one confirmation, attached by both ways in — a row here and the review
/// screen's own button — so the two cannot drift apart. Coach's
/// `RemoveClientAlert` is the same arrangement for the same reason.
struct DeleteOutdoorActivityAlert: ViewModifier {
    @Environment(\.modelContext) private var context
    let activity: OutdoorActivity
    let summary: OutdoorRemoval.Summary
    @Binding var isPresented: Bool
    var onRemoved: () -> Void = {}

    func body(content: Content) -> some View {
        content.alert("Delete this \(summary.typeName.lowercased())?", isPresented: $isPresented) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                if OutdoorRemoval.remove(activity, in: context) { onRemoved() }
            }
        } message: {
            Text(OutdoorRemoval.warning(summary))
        }
    }
}

extension View {
    /// See `DeleteOutdoorActivityAlert`.
    func deletesOutdoorActivity(_ activity: OutdoorActivity,
                                summary: OutdoorRemoval.Summary,
                                isPresented: Binding<Bool>,
                                onRemoved: @escaping () -> Void = {}) -> some View {
        modifier(DeleteOutdoorActivityAlert(activity: activity, summary: summary,
                                            isPresented: isPresented, onRemoved: onRemoved))
    }
}
