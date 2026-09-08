import MapKit
import SwiftData
import SwiftUI

/// Live recording: elapsed time, distance, pace, and a live-updating map
/// trace. `LocationTracker` is the source of truth for points while
/// recording; nothing here reads from HealthKit — that only happens once
/// this screen calls `finish()` and hands off to the review screen.
struct OutdoorActivityRecordingView: View {
    let activityType: OutdoorActivityType

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @AppStorage("distanceUnit") private var unitRaw = DistanceUnit.miles.rawValue

    @State private var tracker = LocationTracker()
    @State private var startedAt = Date.now
    @State private var now = Date.now
    @State private var finishedActivity: OutdoorActivity?

    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var unit: DistanceUnit { DistanceUnit(rawValue: unitRaw) ?? .miles }
    private var elapsed: TimeInterval { now.timeIntervalSince(startedAt) }
    private var distanceMeters: Double { OutdoorActivityMath.totalDistanceMeters(tracker.points) }

    var body: some View {
        VStack(spacing: 16) {
            Map {
                if tracker.points.count > 1 {
                    MapPolyline(coordinates: tracker.points.map {
                        CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
                    })
                    .stroke(.orange, lineWidth: 4)
                }
            }
            .frame(height: 300)

            statsRow

            Button("Finish \(activityType.displayName)", role: .destructive) {
                finish()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .navigationTitle(activityType.displayName)
        .onAppear {
            tracker.requestAuthorization()
            tracker.start()
            startedAt = .now
        }
        .onReceive(tick) { now = $0 }
        .fullScreenCover(item: $finishedActivity) { activity in
            NavigationStack {
                OutdoorActivityReviewView(activity: activity)
            }
        }
    }

    private var statsRow: some View {
        HStack {
            statColumn("Time", formattedElapsed)
            Spacer()
            statColumn("Distance", String(format: "%.2f %@", unit.fromMeters(distanceMeters), unit.abbreviation))
            Spacer()
            statColumn("Pace", pace)
        }
    }

    private func statColumn(_ label: String, _ value: String) -> some View {
        VStack {
            Text(value).font(.title2.monospacedDigit())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var formattedElapsed: String {
        let total = Int(elapsed)
        return String(format: "%02d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
    }

    private var pace: String {
        guard distanceMeters > 0 else { return "--" }
        let secondsPerUnit = elapsed / unit.fromMeters(distanceMeters)
        guard secondsPerUnit.isFinite, secondsPerUnit > 0 else { return "--" }
        let minutes = Int(secondsPerUnit) / 60
        let seconds = Int(secondsPerUnit) % 60
        return String(format: "%d:%02d /%@", minutes, seconds, unit.abbreviation)
    }

    private func finish() {
        tracker.stop()
        let activity = OutdoorActivity(activityType: activityType, startedAt: startedAt)
        activity.endedAt = .now
        activity.routePoints = tracker.points
        activity.distanceMeters = OutdoorActivityMath.totalDistanceMeters(tracker.points)
        activity.elevationGainMeters = OutdoorActivityMath.elevationGainMeters(tracker.points)
        context.insert(activity)
        try? context.save()
        finishedActivity = activity
    }
}

extension OutdoorActivity: Identifiable {}
