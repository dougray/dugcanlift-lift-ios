import SwiftUI
import SwiftData

@main
struct LiftApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .modelContainer(LiftStore.shared)
    }
}
