import HealthKit
import LiftKit
import SwiftUI

/// Live stats screen for a Run or Hike in progress. No map — per the design
/// spec, the watch's job is elapsed time / distance / pace ticking plus a
/// Finish/Discard control, matching this app's minimal-chrome `List`-based
/// screens (`WorkoutView.swift`/`SummaryView.swift`) rather than introducing
/// a different visual language for outdoor activities.
struct OutdoorActivityView: View {
    @EnvironmentObject private var recorder: OutdoorActivityRecorder
    @EnvironmentObject private var library: OutdoorActivityLibrary

    var body: some View {
        List {
            Section {
                LabeledValue("Time", Self.formatElapsed(recorder.elapsedSeconds))
                LabeledValue("Distance", Self.formatDistance(recorder.distanceMeters))
                LabeledValue("Pace", Self.formatPace(recorder.averagePaceSecondsPerKilometer))
            }

            if recorder.elevationGainMeters > 0 {
                Section {
                    LabeledValue("Elevation Gain", Self.formatElevation(recorder.elevationGainMeters))
                }
            }

            Section {
                Button("Finish") { finish() }
                    .buttonStyle(.borderedProminent)
                Button("Discard", role: .destructive) { recorder.discard() }
            }
        }
        .navigationTitle(recorder.activity?.activityType.displayName ?? "Activity")
    }

    /// Finishing hands the recorder's own returned snapshot straight to
    /// `library.finish(_:)` — which stores it immediately and exports it to
    /// HealthKit in the background — then resets the recorder to `nil` so
    /// `RootView` returns to the start screen and a new recording can begin.
    ///
    /// Calling `discard()` right after `finish()` is safe and intentional,
    /// not a mistake: `finish()` already tore down the session/location
    /// updates and captured the finished activity in its return value, so
    /// this second call only clears `recorder.activity` back to `nil` — it
    /// throws nothing away. `OutdoorActivityRecorder` has no dedicated
    /// "reset after finish" API; this is the sanctioned way to get one,
    /// using the same "caller re-assigns/owns the returned copy" contract
    /// the recorder and `OutdoorActivity` already use throughout.
    private func finish() {
        guard let finished = recorder.finish() else { return }
        library.finish(finished)
        recorder.discard()
    }

    // MARK: - Formatting
    //
    // Inline, file-local formatting — matching the convention already used by
    // `ExerciseRow`/`LogSetView` in this app rather than introducing a new
    // LiftKit formatting type. `RestTimer.format(_:)` is mm:ss only and
    // built for a rest interval measured in minutes; a run or hike can run
    // past an hour, so this adds the hour component instead of reusing it.

    private static func formatElapsed(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds).rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%02d:%02d", minutes, secs)
    }

    private static func formatDistance(_ meters: Double) -> String {
        String(format: "%.2f km", meters / 1000)
    }

    private static func formatPace(_ secondsPerKilometer: Double?) -> String {
        guard let secondsPerKilometer, secondsPerKilometer.isFinite else { return "--:-- /km" }
        let total = Int(secondsPerKilometer.rounded())
        return String(format: "%d:%02d /km", total / 60, total % 60)
    }

    private static func formatElevation(_ meters: Double) -> String {
        String(format: "%.0f m", meters)
    }
}

// MARK: - Finished-activity storage + HealthKit export

/// Owns finished outdoor activities on this device and exports each one to
/// HealthKit once. Instantiated once at the app root and injected via
/// `@EnvironmentObject`, the same lifetime pattern `WorkoutSessionModel`
/// already uses — this needs to outlive any one recording so a finished
/// activity's `healthKitUUID` stamp (and the store itself) survives the
/// `OutdoorActivityView` disappearing once `OutdoorActivityRecorder.activity`
/// resets to `nil`.
@MainActor
final class OutdoorActivityLibrary: ObservableObject {
    @Published private(set) var store = OutdoorActivityStore()

    private let exporter = HealthKitExporter(healthStore: HKHealthStore())

    /// Records a just-finished activity immediately, then kicks off its
    /// HealthKit export in the background. Deliberately not `async`/awaited
    /// by the caller: the Finish button's UI transition (back to the start
    /// screen) must not block on a HealthKit write, which can take a moment.
    func finish(_ activity: OutdoorActivity) {
        store.store(activity)
        Task { [weak self] in
            await self?.exportAndMark(activity)
        }
    }

    /// Exports `activity`, then stamps and re-stores the returned UUID via
    /// `OutdoorActivity.markExported(_:)` — the exact "mutate a local copy,
    /// re-assign it" contract that value type requires, matching
    /// `OutdoorActivityRecorder.finish()`'s own `current.finish(at:)` /
    /// `activity = current` shape. Stamping here (after export actually
    /// succeeds) is what lets `HealthKitExporter`'s own
    /// `guard activity.healthKitUUID == nil` protect a future retry from
    /// ever writing the same workout into Health twice.
    private func exportAndMark(_ activity: OutdoorActivity) async {
        do {
            guard let uuid = try await exporter.exportOutdoorActivity(activity) else { return }
            var updated = activity
            guard updated.markExported(uuid) else { return }
            store.store(updated)
        } catch {
            // Non-fatal: the activity is already recorded locally in `store`,
            // and `healthKitUUID` stays `nil` so a later retry path (Task 6's
            // sync work) can still attempt the export again.
        }
    }
}
