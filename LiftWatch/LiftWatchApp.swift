import SwiftUI

@main
struct LiftWatchApp: App {
    @StateObject private var session = WorkoutSessionModel()
    // Instantiated once here, exactly like `session` above: `start(type:)`/
    // `finish()`/`discard()` are all designed to be called repeatedly on one
    // long-lived instance (each `start` guards on `activity == nil`), not
    // re-created per recording.
    @StateObject private var outdoorRecorder = OutdoorActivityRecorder()
    @StateObject private var outdoorLibrary = OutdoorActivityLibrary()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(session)
                .environmentObject(outdoorRecorder)
                .environmentObject(outdoorLibrary)
        }
    }
}
