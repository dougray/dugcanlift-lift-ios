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
    @EnvironmentObject private var outdoorLibrary: OutdoorActivityLibrary
    @State private var focus: TrainingFocus = .bodybuilding
    @State private var retrying = false

    var body: some View {
        List {
            // A finished run whose Health export failed. Shown here because
            // this is where Finish lands; the recording screen that used to
            // carry the message is gone before the export settles.
            if let failed = outdoorLibrary.failedExport {
                Section {
                    Text("Your \(failed.activityType.displayName.lowercased()) is saved on the watch, but didn't reach Health.")
                        .font(.caption2)
                        .foregroundStyle(DclTheme.accentText)
                        // Explicit ground so the caption's contrast is the verified
                        // 4.69:1 on surface, not whatever the system platter is.
                        .listRowBackground(DclTheme.surface)
                    Button(retrying ? "Trying…" : "Try Again") {
                        retrying = true
                        Task {
                            await outdoorLibrary.retryFailedExport()
                            retrying = false
                        }
                    }
                    .disabled(retrying)
                    Button("Not Now") { outdoorLibrary.dismissFailedExport() }
                        .disabled(retrying)
                }
            }

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
                            .foregroundStyle(DclTheme.accent2Text)
                    }
                    // Readable sage is 5.03:1 on surface; pin the row to it.
                    .listRowBackground(DclTheme.surface)
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
