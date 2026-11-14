import SwiftData
import SwiftUI
import LiftCore
import LiftMap

/// Live recording: elapsed time, distance, pace, and a live-updating
/// route. `LocationTracker` is the source of truth for points while
/// recording; nothing here reads from HealthKit — that only happens once
/// this screen calls `finish()` and hands off to the review screen.
///
/// Presentation is owned entirely by the caller: this view reports a
/// finished activity through `ActiveRun.justFinished`. Cancel ends the run
/// through `ActiveRun`, and Back to LIFT only closes this screen: the run goes
/// on, shown on the Train card.
/// It never presents the review screen itself — see `OutdoorDaySection` in
/// TrainView.swift, which presents review as a sibling `.fullScreenCover`, not
/// nested inside this one, so finishing a run can never leave a stale
/// recording screen sitting underneath.
///
/// The recording itself -- tracker, start time, lifecycle -- is the caller's
/// `OutdoorRecording`, not this view's `@State`: switching light and dark
/// rebuilt this view with fresh state mid-run, and a tracker held here was
/// lost with it. This view only reports what happens to it
/// (`RecordingLifecycle` decides what that means).
struct OutdoorActivityRecordingView: View {
    let recording: OutdoorRecording

    @Environment(\.modelContext) private var context
    @Environment(ActiveRun.self) private var activeRun
    @AppStorage("distanceUnit") private var unitRaw = DistanceUnit.miles.rawValue

    @State private var now = Date.now
    @State private var confirmingDiscard = false
    @State private var saveFailed = false

    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var activityType: OutdoorActivityType { recording.activityType }
    private var tracker: LocationTracker { recording.tracker }
    private var unit: DistanceUnit { DistanceUnit(rawValue: unitRaw) ?? .miles }
    /// The same numbers the Train card shows.
    private var stats: LiveRunStats {
        LiveRunStats.compute(points: tracker.points, startedAt: recording.startedAt, now: now)
    }

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
                    // Over the streets you have downloaded, or the line on its
                    // own where you have none. Nothing is fetched either way:
                    // no tile server learns where you are running.
                    RouteMap(points: tracker.points.map {
                        OutdoorShareCoordinate(latitude: $0.latitude, longitude: $0.longitude)
                    }, aspectRatio: 1)

                    statsRow

                    if let line = activeRun.liveHeartRate(now: now) {
                        VStack(spacing: 2) {
                            Text(line.number).font(.title3.monospacedDigit())
                            Text(line.source).font(.caption).foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }

                    // Saves, so not red: the destructive role belongs to
                    // the Cancel that throws a route away. Off while Finish
                    // waits on Health.
                    Button("Finish \(activityType.displayName)") {
                        finish()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .disabled(activeRun.isFinishing)
                }
                .padding()
            }
        }
        .navigationTitle(activityType.displayName)
        .toolbar {
            // The run goes on without this screen: it shows on the Train card,
            // and ends only on Cancel or Finish.
            ToolbarItem(placement: .topBarLeading) {
                Button("Back to LIFT") { activeRun.close() }
            }
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
        // Reported, not acted on: a disappear followed at once by an appear is
        // SwiftUI rebuilding this screen (a light/dark switch does it), not the
        // person leaving it. `RecordingLifecycle` starts the run on the first
        // appear only (`ActiveRun.start` already did) and stops it only on Cancel or Finish.
        .onAppear { recording.handle(.appear) }
        .onDisappear { recording.handle(.disappear) }
        .onReceive(tick) { now = $0 }
    }

    private var statsRow: some View {
        let stats = stats
        return HStack {
            statColumn("Time", stats.elapsedText)
            Spacer()
            statColumn("Distance", stats.distanceText(unit: unit))
            Spacer()
            statColumn("Pace", stats.paceText(unit: unit))
        }
    }

    private func statColumn(_ label: String, _ value: String) -> some View {
        VStack {
            Text(value).font(.title2.monospacedDigit())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func finish() {
        // Tracking stops only once the save has worked: a failed save keeps
        // recording, so nothing walked after it is lost either.
        Task { @MainActor in
            do {
                _ = try await activeRun.finish(in: context)
            } catch ActiveRun.FinishError.notRecording {
                // A second tap of Finish landing after the first one saved, or
                // a Cancel that came while Health was asked: nothing to say.
            } catch {
                // Nothing is presented on a failed save: leave the user on this
                // screen, tell them, and let them try Finish again, rather than
                // silently losing the run.
                saveFailed = true
            }
        }
    }

    private func discard() {
        activeRun.cancel()
    }
}
