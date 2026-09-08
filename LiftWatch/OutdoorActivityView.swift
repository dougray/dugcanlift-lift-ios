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
    /// `library.finish(_:)`, then resets the recorder to `nil` immediately so
    /// `RootView` returns to the start screen without waiting on the
    /// HealthKit export — the UI must not block on a write that can take a
    /// moment.
    ///
    /// The `HKWorkoutSession` is deliberately kept alive across that gap:
    /// `recorder.finish()` only tears down the location manager (GPS is no
    /// longer needed), not the session. The session — and the background
    /// runtime it grants — stays live until `library.finish(_:)`'s export
    /// attempt (success or failure) has actually completed, at which point
    /// `endHealthKitSession(at:)` ends it. This closes the gap where dropping
    /// the wrist right after tapping Finish could suspend the app before an
    /// export in flight ever ran.
    private func finish() {
        guard let finished = recorder.finish() else { return }
        recorder.resetAfterFinish()
        Task {
            await library.finish(finished)
            recorder.endHealthKitSession(at: finished.endedAt ?? Date())
        }
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

    /// Set when the most recent HealthKit export attempt failed; cleared to
    /// `nil` on a successful export. Surfaced to the user in
    /// `OutdoorActivityView` (see I3 in the final-review fix wave) so a
    /// failed, non-retried export is never silently swallowed.
    @Published private(set) var lastExportError: Error?

    private let exporter = HealthKitExporter(healthStore: HKHealthStore())

    /// The app's one `WorkoutSessionModel`, injected from `LiftWatchApp`.
    /// `OutdoorActivityLibrary` has no `SyncOutbox`/`PhoneSyncTransport` of
    /// its own on purpose — see `WorkoutSessionModel.
    /// enqueueOutdoorActivityFinished(id:revision:updatedAt:)` for why a
    /// second `PhoneSyncTransport` would conflict with this one over
    /// `WCSession`'s single delegate slot. Reusing `session`'s outbox is the
    /// cheaper, conflict-free way to notify the phone.
    private let session: WorkoutSessionModel

    init(session: WorkoutSessionModel) {
        self.session = session
    }

    /// Records a just-finished activity immediately, then awaits its
    /// HealthKit export. `async` rather than fire-and-forget: the caller
    /// (`OutdoorActivityView.finish()`) needs to know when the export
    /// attempt has settled so it can end the `HKWorkoutSession` only then —
    /// not before, or a dropped wrist right after tapping Finish could
    /// suspend the app mid-export with no way to retry. The UI itself still
    /// doesn't block on this: the caller resets the recorder back to the
    /// start screen first, then awaits this in its own `Task`.
    func finish(_ activity: OutdoorActivity) async {
        store.store(activity)
        session.enqueueOutdoorActivityFinished(
            id: activity.id,
            revision: activity.revision,
            updatedAt: activity.updatedAt
        )
        await exportAndMark(activity)
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
            lastExportError = nil
        } catch {
            // Non-fatal: the activity is already recorded locally in
            // `store`, and `healthKitUUID` stays `nil`. There is currently
            // no automatic retry path — the failure is recorded in
            // `lastExportError` (surfaced to the user in
            // `OutdoorActivityView`) so it isn't silently swallowed.
            lastExportError = error
        }
    }
}
