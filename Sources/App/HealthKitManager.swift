import Foundation
import HealthKit
import SwiftData

/// HealthKit integration.
///
/// The critical invariant: every write records its returned UUID on the model
/// before the next sync runs. Background sync retries on failure, and without
/// an idempotency key each retry writes another copy into the Health app —
/// which users notice immediately and cannot easily clean up.
@Observable
final class HealthKitManager {

    static let shared = HealthKitManager()

    private let store = HKHealthStore()

    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }
    var lastSyncError: String?

    private var shareTypes: Set<HKSampleType> {
        var types: Set<HKSampleType> = [HKObjectType.workoutType()]
        if let bodyMass = HKQuantityType.quantityType(forIdentifier: .bodyMass) {
            types.insert(bodyMass)
        }
        if let energy = HKQuantityType.quantityType(forIdentifier: .dietaryEnergyConsumed) {
            types.insert(energy)
        }
        if let protein = HKQuantityType.quantityType(forIdentifier: .dietaryProtein) {
            types.insert(protein)
        }
        return types
    }

    private var readTypes: Set<HKObjectType> {
        var types: Set<HKObjectType> = [HKObjectType.workoutType()]
        if let bodyMass = HKQuantityType.quantityType(forIdentifier: .bodyMass) {
            types.insert(bodyMass)
        }
        if let steps = HKQuantityType.quantityType(forIdentifier: .stepCount) {
            types.insert(steps)
        }
        return types
    }

    // MARK: Authorization

    func requestAuthorization() async throws {
        guard isAvailable else { return }
        try await store.requestAuthorization(toShare: shareTypes, read: readTypes)
    }

    /// Note this only ever reports write permission. HealthKit deliberately
    /// never reveals whether read access was granted — an app that could tell
    /// the difference could infer that the user has something to hide.
    func writeStatus(for type: HKSampleType) -> HKAuthorizationStatus {
        store.authorizationStatus(for: type)
    }

    var isWorkoutWritingAuthorized: Bool {
        writeStatus(for: HKObjectType.workoutType()) == .sharingAuthorized
    }

    // MARK: Workouts

    /// Writes a finished session to HealthKit and stamps it with the returned
    /// UUID. Returns silently if the session was already synced.
    @discardableResult
    func sync(_ day: WorkoutDay) async throws -> UUID? {
        guard isAvailable, day.healthKitUUID == nil, day.totalSetCount > 0 else { return nil }

        // A live session gives real timestamps. A retroactively logged day has
        // none, so estimate a window from set count — flagged in metadata so
        // the approximation is visible rather than silently presented as fact.
        let start: Date
        let end: Date
        if let liveStart = day.liveStartedAt, let liveEnd = day.liveEndedAt {
            start = liveStart
            end = liveEnd
        } else {
            let noon = Calendar.current.date(
                bySettingHour: 12, minute: 0, second: 0, of: day.date) ?? day.date
            start = noon
            end = noon.addingTimeInterval(Double(day.totalSetCount) * 150)
        }

        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .traditionalStrengthTraining
        configuration.locationType = .indoor

        // HKWorkout's initialisers are deprecated as of iOS 17; the builder is
        // the supported path for writing a workout that already happened.
        let builder = HKWorkoutBuilder(
            healthStore: store,
            configuration: configuration,
            device: .local()
        )

        try await builder.beginCollection(at: start)

        var metadata: [String: Any] = [
            HKMetadataKeyWorkoutBrandName: "Lift"
        ]
        if day.totalVolumeKg > 0 {
            metadata["LiftTotalVolumeKg"] = day.totalVolumeKg
        }
        metadata["LiftExerciseCount"] = day.exercises.count
        metadata["LiftEstimatedTimes"] = (day.liveStartedAt == nil)
        try await builder.addMetadata(metadata)

        try await builder.endCollection(at: end)

        guard let workout = try await builder.finishWorkout() else { return nil }

        // Stamp BEFORE anything else can fail, so a later error can't cause a
        // duplicate write on the next attempt.
        day.healthKitUUID = workout.uuid
        return workout.uuid
    }

    /// Syncs every finished, unsynced session. Safe to call repeatedly.
    func syncPending(context: ModelContext) async {
        guard isAvailable, isWorkoutWritingAuthorized else { return }

        let descriptor = FetchDescriptor<WorkoutDay>(
            predicate: #Predicate { $0.healthKitUUID == nil }
        )

        do {
            let pending = try context.fetch(descriptor)
            for day in pending {
                try await sync(day)
            }
            if !pending.isEmpty { try context.save() }
            lastSyncError = nil
        } catch {
            lastSyncError = error.localizedDescription
        }
    }

    // MARK: Body mass

    func saveBodyMass(kilograms: Double, date: Date = .now) async throws -> UUID? {
        guard isAvailable,
              let type = HKQuantityType.quantityType(forIdentifier: .bodyMass) else { return nil }

        let quantity = HKQuantity(unit: .gramUnit(with: .kilo), doubleValue: kilograms)
        let sample = HKQuantitySample(type: type, quantity: quantity, start: date, end: date)
        try await store.save(sample)
        return sample.uuid
    }

    /// Most recent body mass recorded by any app — the Health app, a smart
    /// scale, or Lift itself.
    func latestBodyMassKg() async throws -> (kilograms: Double, date: Date)? {
        guard isAvailable,
              let type = HKQuantityType.quantityType(forIdentifier: .bodyMass) else { return nil }

        let descriptor = HKSampleQueryDescriptor(
            predicates: [.quantitySample(type: type)],
            sortDescriptors: [SortDescriptor(\.endDate, order: .reverse)],
            limit: 1
        )

        let results = try await descriptor.result(for: store)
        guard let sample = results.first else { return nil }
        return (sample.quantity.doubleValue(for: .gramUnit(with: .kilo)), sample.endDate)
    }

    // MARK: Steps

    /// Sum of step count samples from midnight to now, from any source (iPhone,
    /// Watch, or a third-party app) — whatever Health itself considers today's
    /// total.
    func todaysStepCount() async throws -> Double {
        guard isAvailable,
              let type = HKQuantityType.quantityType(forIdentifier: .stepCount) else { return 0 }

        let start = Calendar.current.startOfDay(for: .now)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: .now)
        let descriptor = HKStatisticsQueryDescriptor(
            predicate: .quantitySample(type: type, predicate: predicate),
            options: .cumulativeSum
        )

        let statistics = try await descriptor.result(for: store)
        return statistics?.sumQuantity()?.doubleValue(for: .count()) ?? 0
    }
}
