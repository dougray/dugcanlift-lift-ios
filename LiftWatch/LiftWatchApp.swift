import SwiftUI

@main
struct LiftWatchApp: App {
    @StateObject private var session: WorkoutSessionModel
    // Instantiated once here, exactly like `session` above: `start(type:)`/
    // `finish()`/`discard()` are all designed to be called repeatedly on one
    // long-lived instance (each `start` guards on `activity == nil`), not
    // re-created per recording.
    @StateObject private var outdoorRecorder: OutdoorActivityRecorder
    @StateObject private var outdoorLibrary: OutdoorActivityLibrary

    // A custom `init` (rather than each property's own default expression)
    // is what lets `outdoorLibrary` be handed the same `session` instance
    // this scene injects everywhere else, so its finished-activity
    // notification rides `session`'s existing `SyncOutbox`/
    // `PhoneSyncTransport` instead of standing up a second `WCSession`
    // delegate (see `WorkoutSessionModel.enqueueOutdoorActivityFinished`).
    init() {
        let session = WorkoutSessionModel()
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
        }
    }
}
