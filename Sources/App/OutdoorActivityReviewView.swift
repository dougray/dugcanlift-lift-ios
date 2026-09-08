import MapKit
import SwiftUI

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

    private var unit: DistanceUnit { DistanceUnit(rawValue: unitRaw) ?? .miles }

    var body: some View {
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
        .navigationTitle(activity.activityType.displayName)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
            ToolbarItem(placement: .destructiveAction) {
                Button("Discard", role: .destructive) {
                    context.delete(activity)
                    try? context.save()
                    dismiss()
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
    }

    private func formatted(_ duration: TimeInterval) -> String {
        let total = Int(duration)
        return String(format: "%02d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
    }
}
