import LiftKit
import SwiftUI

struct RootView: View {
    @EnvironmentObject private var session: WorkoutSessionModel

    var body: some View {
        NavigationStack {
            if session.draft == nil {
                StartWorkoutView()
            } else {
                WorkoutView()
            }
        }
    }
}

struct StartWorkoutView: View {
    @EnvironmentObject private var session: WorkoutSessionModel
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
        }
        .navigationTitle("LIFT")
    }
}
