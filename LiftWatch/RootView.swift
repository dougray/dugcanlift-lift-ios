import LiftKit
import SwiftUI

struct RootView: View {
    @EnvironmentObject private var session: WorkoutSessionModel
    @EnvironmentObject private var outdoorRecorder: OutdoorActivityRecorder

    var body: some View {
        NavigationStack {
            // An in-progress outdoor recording takes priority: once
            // `start(type:)` is called, `activity` stays non-nil (even right
            // after `finish()`, until `OutdoorActivityView` resets it) so
            // this is the state that should own the screen.
            if outdoorRecorder.activity != nil {
                OutdoorActivityView()
            } else if session.draft == nil {
                StartWorkoutView()
            } else {
                WorkoutView()
            }
        }
    }
}

struct StartWorkoutView: View {
    @EnvironmentObject private var session: WorkoutSessionModel
    @EnvironmentObject private var outdoorRecorder: OutdoorActivityRecorder
    @State private var focus: TrainingFocus = .bodybuilding

    var body: some View {
        List {
            Section {
                Picker("Focus", selection: $focus) {
                    ForEach(TrainingFocus.allCases) { option in
                        Text(option.displayName).tag(option)
                    }
                }
            }
            Section {
                Button("Start Workout") {
                    session.startWorkout(named: focus.displayName, focus: focus)
                }
            }
            Section {
                Button("Start Run") {
                    outdoorRecorder.start(type: .run)
                }
                Button("Start Hike") {
                    outdoorRecorder.start(type: .hike)
                }
            }
            Section {
                NavigationLink("Log Food") {
                    RecentFoodsListView()
                }
                NavigationLink("All Foods") {
                    FoodSearchView()
                }
                NavigationLink("Export Foods") {
                    ExportFoodsView()
                }
            }
        }
        .navigationTitle("LIFT")
    }
}
