import SwiftUI

@main
struct LiftWatchApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var session: WorkoutSessionModel
    // Instantiated once here, exactly like `session` above: `start(type:)`/
    // `finish()`/`discard()` are all designed to be called repeatedly on one
    // long-lived instance (each `start` guards on `activity == nil`), not
    // re-created per recording.
    @StateObject private var outdoorRecorder: OutdoorActivityRecorder
    @StateObject private var outdoorLibrary: OutdoorActivityLibrary
    // The lifting session's HealthKit half. Built here for the same reason
    // `outdoorRecorder` is: one long-lived instance, started and finished
    // repeatedly, and the same object the model ends and the Now screen
    // reads a heart rate from.
    @StateObject private var heartRate: LiftingSessionRecorder

    // A custom `init` (rather than each property's own default expression)
    // is what lets `outdoorLibrary` be handed the same `session` instance
    // this scene injects everywhere else, so its finished-activity
    // notification rides `session`'s existing `SyncOutbox`/
    // `PhoneSyncTransport` instead of standing up a second `WCSession`
    // delegate (see `WorkoutSessionModel.enqueueOutdoorActivityFinished`).
    init() {
        let heartRate = LiftingSessionRecorder()
        let session = WorkoutSessionModel(heartRate: heartRate)
        _heartRate = StateObject(wrappedValue: heartRate)
        _session = StateObject(wrappedValue: session)
        _outdoorRecorder = StateObject(wrappedValue: OutdoorActivityRecorder())
        _outdoorLibrary = StateObject(wrappedValue: OutdoorActivityLibrary(session: session))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(session)
                .environmentObject(outdoorRecorder)
                .environmentObject(outdoorLibrary)
                .environmentObject(heartRate)
                // Applied once at the root rather than per screen: every view
                // below inherits the palette, so a new screen is themed by
                // default instead of by remembering to be.
                .liftWatchTheme()
                // Becoming active is the moment the plan matters and the
                // moment it is most likely to be stale — the phone may have
                // accepted a coach's plan while this app was asleep.
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { session.requestPlan() }
                }
        }
    }
}
