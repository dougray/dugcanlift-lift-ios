import SwiftUI
import SwiftData
import HealthKit

struct SettingsView: View {
    @Environment(\.modelContext) private var context

    @AppStorage("weightUnit") private var unitRaw = WeightUnit.pounds.rawValue

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
                }

                CoachSection()

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
                    } else {
                        Button("Connect Apple Health", systemImage: "heart.fill") {
                            authorize()
                        }
                        .disabled(isRequesting)
                        Text("Lift writes your workouts to Health and can read your body weight.")
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
            .navigationTitle("Settings")
            .task { await loadWeight() }
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
                try await health.requestAuthorization()
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
