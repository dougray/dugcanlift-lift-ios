import SwiftUI
import SwiftData
import HealthKit
import LiftCore
import LiftMap
import LiftMapCore

struct SettingsView: View {
    @Environment(\.modelContext) private var context

    @AppStorage("weightUnit") private var unitRaw = WeightUnit.pounds.rawValue
    @AppStorage("distanceUnit") private var distanceUnitRaw = DistanceUnit.miles.rawValue
    @AppStorage("servingUnit") private var servingUnitRaw = ServingUnit.grams.rawValue
    @AppStorage(WatchPlanSettings.restSecondsKey) private var watchRestSeconds =
        WatchPlanSettings.defaultRestSeconds
    @AppStorage(LiveSessionScreen.enabledKey) private var keepsScreenOn =
        LiveSessionScreen.defaultEnabled
    @AppStorage(ProgressionRule.enabledKey) private var suggestsNextWeight = true

    @Query(filter: #Predicate<WorkoutDay> { $0.healthKitUUID == nil })
    private var unsynced: [WorkoutDay]

    @State private var health = HealthKitManager.shared
    @State private var isRequesting = false
    @State private var latestWeight: String?
    /// Where the newest recorded run began, for the Maps section to offer.
    @State private var lastRunStart: (Double, Double)?
    @State private var oneFix = OneLocationFix()

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
                    Text("System follows this device's light or dark setting.")
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

                // The watch shows weights and distances in these units too;
                // it hears about a change on the next context push.
                .onChange(of: unitRaw) { WatchSyncReceiver.shared?.pushRecentFoodsSnapshot() }
                .onChange(of: distanceUnitRaw) { WatchSyncReceiver.shared?.pushRecentFoodsSnapshot() }

                // Street maps are drawn from areas the person downloads here;
                // nothing downloads or updates on its own. No store (the file
                // could not be opened) means no section rather than a broken one.
                if let streets = StreetStore.shared {
                    MapsSection(store: streets,
                                location: { await oneFix.current() },
                                lastRunStart: lastRunStart)
                }

                HeartRateSettingsSection()

                Section {
                    Stepper(value: $watchRestSeconds,
                            in: WatchPlanSettings.restSecondsRange,
                            step: WatchPlanSettings.restSecondsStep) {
                        LabeledContent("Rest between sets",
                                       value: SetMetrics.clock(watchRestSeconds))
                    }
                    Toggle("Keep the screen on", isOn: $keepsScreenOn)
                    Toggle("Suggest the next weight", isOn: $suggestsNextWeight)
                    NavigationLink("Plates and bars") {
                        PlateSettingsView()
                    }
                    NavigationLink("My equipment") {
                        MyEquipmentView()
                    }
                } header: {
                    Text("Training")
                } footer: {
                    Text("In a live session, tick a set done to start your rest. If you allow notifications, LIFT tells you when it's over, even with your phone locked. Your Apple Watch rests for the same time. While a live session is running, the screen doesn't lock. Plates and bars work out what to load for a set on a bar. My equipment narrows exercise search to what you have. For an exercise from one of your own routines, LIFT suggests the next weight from your last session: up a step when every set reached its reps, the same again when one didn't, and a little lighter after two short sessions in a row.")
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
                    attribution(
                        "Street maps",
                        detail: "© OpenStreetMap contributors (ODbL), vector tiles from OpenFreeMap. Drawn with MapLibre Native (BSD 2-Clause). Street names in Noto Sans (SIL Open Font License 1.1)."
                    )
                    NavigationLink("Map licenses") {
                        MapLicenseView()
                    }
                }
            }
            .readableListMargins()
            .navigationTitle("Settings")
            .task {
                lastRunStart = newestRunStart()
                await health.refreshAuthorizationState()
                await loadWeight()
            }
        }
    }

    /// The first recorded point of the newest run, if it recorded any. One
    /// row is fetched, not every run with its route.
    private func newestRunStart() -> (Double, Double)? {
        var newest = FetchDescriptor<OutdoorActivity>(
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)])
        newest.fetchLimit = 1
        guard let first = (try? context.fetch(newest))?.first?.routePoints.first else { return nil }
        return (first.latitude, first.longitude)
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
