import SwiftUI
import SwiftData
import HealthKit
import LiftCore

struct SettingsView: View {
    @Environment(\.modelContext) private var context

    @AppStorage("weightUnit") private var unitRaw = WeightUnit.pounds.rawValue
    @AppStorage("distanceUnit") private var distanceUnitRaw = DistanceUnit.miles.rawValue
    @AppStorage("servingUnit") private var servingUnitRaw = ServingUnit.grams.rawValue
    @AppStorage(WatchPlanSettings.restSecondsKey) private var watchRestSeconds =
        WatchPlanSettings.defaultRestSeconds

    @Query(filter: #Predicate<WorkoutDay> { $0.healthKitUUID == nil })
    private var unsynced: [WorkoutDay]

    @State private var health = HealthKitManager.shared
    @State private var isRequesting = false
    @State private var latestWeight: String?

    private var unit: WeightUnit {
        WeightUnit(rawValue: unitRaw) ?? .kilograms
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    AppearancePicker()
                } header: {
                    Text("Appearance")
                } footer: {
                    Text("System follows your phone's light or dark setting.")
                }

                Section("Units") {
                    Picker("Weight", selection: $unitRaw) {
                        ForEach(WeightUnit.allCases, id: \.rawValue) { unit in
                            Text(unit.abbreviation).tag(unit.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text("Weights are always stored in kilograms; this only changes how they're shown.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Picker("Distance", selection: $distanceUnitRaw) {
                        ForEach(DistanceUnit.allCases, id: \.rawValue) { unit in
                            Text(unit.abbreviation).tag(unit.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text("Distances are always stored in meters; this only changes how they're shown.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Picker("Serving size", selection: $servingUnitRaw) {
                        ForEach(ServingUnit.allCases, id: \.rawValue) { unit in
                            Text(unit.abbreviation).tag(unit.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text("Serving amounts are always stored in grams; this only changes how they're shown.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Stepper(value: $watchRestSeconds,
                            in: WatchPlanSettings.restSecondsRange,
                            step: WatchPlanSettings.restSecondsStep) {
                        LabeledContent("Rest between sets",
                                       value: SetMetrics.clock(watchRestSeconds))
                    }
                } header: {
                    Text("Apple Watch")
                } footer: {
                    Text("Sent with every prescribed set, so the watch starts resting on its own when you log one. A routine itself carries no rest time.")
                }

                CoachSection()

                BackupSection()

                Section("Apple Health") {
                    if !health.isAvailable {
                        Text("Not available on this device")
                            .foregroundStyle(.secondary)
                    } else if health.isWorkoutWritingAuthorized {
                        Label("Connected", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)

                        LabeledContent("Waiting to sync", value: "\(unsynced.count)")

                        Button("Sync now", systemImage: "arrow.triangle.2.circlepath") {
                            Task { await health.syncPending(context: context) }
                        }
                        .disabled(unsynced.isEmpty)

                        if let latestWeight {
                            LabeledContent("Latest weight", value: latestWeight)
                        }
                    } else if health.requestStatus == .unnecessary {
                        // Already asked, and HealthKit will not show the sheet
                        // again: a "Connect" button here would do nothing.
                        Button("Open Settings", systemImage: "gear") {
                            HealthSettingsLink.open()
                        }
                        Text("Lift has asked already, so iOS won't ask again. To let Lift write your workouts, runs, walks and hikes and read your body weight and steps, turn them on in Settings › Privacy & Security › Health › LIFT.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Button("Connect Apple Health", systemImage: "heart.fill") {
                            authorize()
                        }
                        .disabled(isRequesting)
                        Text("Lift writes your workouts, runs, walks and hikes to Health, and reads your body weight and steps.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if let error = health.lastSyncError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                Section("Data sources") {
                    attribution(
                        "Exercises",
                        detail: "free-exercise-db (public domain) and wger (CC BY-SA 3.0)"
                    )
                    attribution(
                        "Food",
                        detail: "USDA FoodData Central (public domain) and Open Food Facts (ODbL)"
                    )
                    Text("These databases are distributed separately under their own licenses.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .readableListMargins()
            .navigationTitle("Settings")
            .task {
                await health.refreshAuthorizationState()
                await loadWeight()
            }
        }
    }

    private func attribution(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func authorize() {
        isRequesting = true
        Task {
            defer { isRequesting = false }
            do {
                if try await health.authorize(.userAction) == .openSettings {
                    HealthSettingsLink.open()
                    return
                }
                await health.syncPending(context: context)
                await loadWeight()
            } catch {
                health.lastSyncError = error.localizedDescription
            }
        }
    }

    private func loadWeight() async {
        guard health.isAvailable else { return }
        if let latest = try? await health.latestBodyMassKg() {
            let value = unit.fromKilograms(latest.kilograms)
            latestWeight = String(format: "%.1f %@", value, unit.abbreviation)
        }
    }
}
