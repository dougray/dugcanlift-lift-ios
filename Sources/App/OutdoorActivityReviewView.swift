import MapKit
import SwiftUI
import LiftCore

/// Shown once a recording finishes. The activity is already saved locally
/// (OutdoorActivityRecordingView inserted it) — this screen's job is
/// showing the full route and triggering the HealthKit export.
struct OutdoorActivityReviewView: View {
    let activity: OutdoorActivity

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @AppStorage("distanceUnit") private var unitRaw = DistanceUnit.miles.rawValue
    @State private var exportError: String?
    @State private var isExporting = true
    @State private var confirmingDelete = false
    @State private var summary = OutdoorRemoval.Summary()
    /// Set the moment the activity is deleted, before this screen leaves.
    /// Every line of the body below reads an `OutdoorActivity` that no longer
    /// exists -- the guard Coach's `ClientDetailView` puts on the same
    /// situation, for the same reason.
    @State private var removed = false

    private var unit: DistanceUnit { DistanceUnit(rawValue: unitRaw) ?? .miles }

    var body: some View {
        if removed {
            Color.clear
        } else {
            activityBody
        }
    }

    private var activityBody: some View {
        List {
            Map {
                if activity.routePoints.count > 1 {
                    MapPolyline(coordinates: activity.routePoints.map {
                        CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
                    })
                    .stroke(.orange, lineWidth: 4)
                }
            }
            .frame(height: 250)
            .listRowInsets(EdgeInsets())

            Section {
                LabeledContent("Distance", value: String(
                    format: "%.2f %@", unit.fromMeters(activity.distanceMeters), unit.abbreviation
                ))
                if let duration = activity.duration {
                    LabeledContent("Duration", value: formatted(duration))
                }
                LabeledContent("Elevation gain", value: String(
                    format: "%.0f m", activity.elevationGainMeters
                ))
            }
        }
        .readableListMargins()
        .navigationTitle(activity.activityType.displayName)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
            ToolbarItem(placement: .destructiveAction) {
                // "Delete", not "Discard": this screen is also how a run
                // recorded months ago is opened from the Outdoor list, where
                // discarding is the wrong word for it -- and the button did
                // the same thing to both with no question asked and no word
                // about the workout it had just written to Health. It goes
                // through `OutdoorRemoval` and the shared confirmation now,
                // so it and the list's own button cannot drift apart.
                Button("Delete", role: .destructive) {
                    summary = OutdoorRemoval.summary(for: activity, in: context)
                    confirmingDelete = true
                }
                .disabled(isExporting)
            }
        }
        .task {
            defer { isExporting = false }
            do {
                try await HealthKitManager.shared.exportOutdoorActivity(activity)
                try? context.save()
            } catch {
                exportError = error.localizedDescription
            }
        }
        .alert("Couldn't save to Health", isPresented: .constant(exportError != nil), presenting: exportError) { _ in
            Button("OK") { exportError = nil }
        } message: { Text($0) }
        .deletesOutdoorActivity(activity, summary: summary, isPresented: $confirmingDelete) {
            removed = true
            dismiss()
        }
    }

    private func formatted(_ duration: TimeInterval) -> String {
        let total = Int(duration)
        return String(format: "%02d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
    }
}
