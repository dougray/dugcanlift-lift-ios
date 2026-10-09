import MapKit
import SwiftData
import SwiftUI
import LiftCore

/// Live recording: elapsed time, distance, pace, and a live-updating map
/// trace. `LocationTracker` is the source of truth for points while
/// recording; nothing here reads from HealthKit — that only happens once
/// this screen calls `finish()` and hands off to the review screen.
///
/// Presentation is owned entirely by the caller: this view reports a
/// finished activity via `onFinish` and otherwise dismisses itself (Cancel).
/// It never presents the review screen itself — see `OutdoorActivityListView`,
/// which presents review as a sibling `.fullScreenCover`, not nested inside
/// this one, so finishing a run can never leave a stale recording screen
/// sitting underneath.
struct OutdoorActivityRecordingView: View {
    let activityType: OutdoorActivityType
    let onFinish: (OutdoorActivity) -> Void

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @AppStorage("distanceUnit") private var unitRaw = DistanceUnit.miles.rawValue

    @State private var tracker = LocationTracker()
    @State private var startedAt = Date.now
    @State private var now = Date.now
    @State private var confirmingDiscard = false
    @State private var saveFailed = false

    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var unit: DistanceUnit { DistanceUnit(rawValue: unitRaw) ?? .miles }
    private var elapsed: TimeInterval { now.timeIntervalSince(startedAt) }
    private var distanceMeters: Double { OutdoorActivityMath.totalDistanceMeters(tracker.points) }

    var body: some View {
        Group {
            if tracker.authorizationStatus == .denied || tracker.authorizationStatus == .restricted {
                ContentUnavailableView(
                    "Location Access Needed",
                    systemImage: "location.slash",
                    description: Text("Enable location access for Lift in Settings to record a route.")
                )
            } else {
                VStack(spacing: 16) {
                    Map {
                        if tracker.points.count > 1 {
                            MapPolyline(coordinates: tracker.points.map {
                                CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
                            })
                            .stroke(Theme.accent, lineWidth: 4)
                        }
                    }
                    .frame(height: 300)

                    statsRow

                    // Saves, so not red: the destructive role belongs to
                    // the Cancel that throws a route away.
                    Button("Finish \(activityType.displayName)") {
                        finish()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                }
                .padding()
            }
        }
        .navigationTitle(activityType.displayName)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                // "Cancel" in this slot reads as "close the screen", but it
                // throws the whole route away. Once there is a route to
                // lose, it asks first.
                Button("Cancel", role: .cancel) {
                    if tracker.points.isEmpty {
                        discard()
                    } else {
                        confirmingDiscard = true
                    }
                }
                .confirmationDialog(
                    "Discard this \(activityType.displayName.lowercased())?",
                    isPresented: $confirmingDiscard,
                    titleVisibility: .visible
                ) {
                    Button("Discard \(activityType.displayName)", role: .destructive) { discard() }
                    Button("Keep Recording", role: .cancel) {}
                } message: {
                    Text("The route, time and distance won't be saved.")
                }
            }
        }
        .alert("Couldn't save this \(activityType.displayName.lowercased())", isPresented: $saveFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Still recording, and the route so far is kept. Try Finish again.")
        }
        .onAppear {
            guard !tracker.isTracking else { return }
            tracker.requestAuthorization()
            tracker.start()
            startedAt = .now
        }
        .onDisappear {
            tracker.stop()
        }
        .onReceive(tick) { now = $0 }
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
        .accessibilityElement(children: .combine)
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
        // Tracking stops only once the save has worked: a failed save keeps
        // recording, so nothing walked after it is lost either.
        let activity = OutdoorActivity(activityType: activityType, startedAt: startedAt)
        activity.endedAt = .now
        activity.routePoints = tracker.points
        activity.distanceMeters = OutdoorActivityMath.totalDistanceMeters(tracker.points)
        activity.elevationGainMeters = OutdoorActivityMath.elevationGainMeters(tracker.points)
        context.insert(activity)
        do {
            try context.save()
            tracker.stop()
            onFinish(activity)
        } catch {
            // Do not call onFinish or dismiss on a failed save: leave the
            // user on this screen, tell them, and let them try Finish again,
            // rather than silently losing the run. The unsaved insert is
            // backed out so a retry doesn't save two copies.
            context.delete(activity)
            saveFailed = true
        }
    }

    private func discard() {
        tracker.stop()
        dismiss()
    }
}
