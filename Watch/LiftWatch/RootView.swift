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
            // Today's plan, when the phone has pushed one. Everything below
            // it is unchanged: a day with no plan is the free-entry flow this
            // app has always had, in the same place on the same screen.
            if let plan = session.todaysPlan {
                Section {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(plan.name)
                            .font(.headline)
                            .lineLimit(2)
                        Text("\(plan.exercises.count) exercises · \(plan.totalSetCount) sets")
                            .font(.caption2)
                            .foregroundStyle(DclTheme.muted)
                        Text(plan.source.displayName)
                            .font(.caption2)
                            .foregroundStyle(DclTheme.accent2)
                    }
                    Button("Start Plan") {
                        session.startPlannedWorkout()
                    }
                } header: {
                    Text("Today")
                }
            }

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
                // Asking is cheap and the answer is queued by the OS, so this
                // works with the phone in a locker — it just arrives later.
                Button(session.todaysPlan == nil ? "Get Today's Plan" : "Refresh Plan") {
                    session.requestPlan(force: true)
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
