import SwiftUI

@main
struct LiftWatchApp: App {
    @StateObject private var session = WorkoutSessionModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(session)
        }
    }
}
