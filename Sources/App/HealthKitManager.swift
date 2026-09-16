import CoreLocation
import Foundation
import HealthKit
import SwiftData
import LiftCore

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
        // Only what this file writes: strength workouts (`sync`) and outdoor
        // workouts with their route (`exportOutdoorActivity`). Food is not
        // written to Health, and neither is body weight, so neither is asked
        // for -- App Review rejects permissions the app does not use.
        var types: Set<HKSampleType> = [HKObjectType.workoutType(), HKSeriesType.workoutRoute()]
        // exportOutdoorActivity writes a distanceWalkingRunning sample — without
        // requesting share authorization for it too, HealthKit silently drops
        // that sample rather than throwing, so a run's distance would never
        // actually persist.
        if let distance = HKQuantityType.quantityType(forIdentifier: .distanceWalkingRunning) {
            types.insert(distance)
        }
        return types
    }

    /// Only what this file reads: body weight (`latestBodyMassKg`) and steps
    /// (`todaysStepCount`, `dailyStepCounts`). Nothing queries workouts.
    private var readTypes: Set<HKObjectType> {
        var types: Set<HKObjectType> = []
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

    /// Exports a finished outdoor activity's workout and route to
    /// HealthKit. Mirrors `sync(_:)`'s idempotency: returns early if already
    /// exported, stamps the UUID immediately on success so a later failure
    /// elsewhere can never cause a duplicate write on retry.
    @discardableResult
    func exportOutdoorActivity(_ activity: OutdoorActivity) async throws -> UUID? {
        guard isAvailable, activity.healthKitUUID == nil,
              let endedAt = activity.endedAt else { return nil }

        let configuration = HKWorkoutConfiguration()
        switch activity.activityType {
        case .run:  configuration.activityType = .running
        case .walk: configuration.activityType = .walking
        case .hike: configuration.activityType = .hiking
        }
        configuration.locationType = .outdoor

        let builder = HKWorkoutBuilder(
            healthStore: store,
            configuration: configuration,
            device: .local()
        )

        try await builder.beginCollection(at: activity.startedAt)

        var metadata: [String: Any] = [HKMetadataKeyWorkoutBrandName: "Lift"]
        metadata["LiftElevationGainMeters"] = activity.elevationGainMeters
        try await builder.addMetadata(metadata)

        if let distanceType = HKQuantityType.quantityType(forIdentifier: .distanceWalkingRunning),
           activity.distanceMeters > 0 {
            let sample = HKCumulativeQuantitySample(
                type: distanceType,
                quantity: HKQuantity(unit: .meter(), doubleValue: activity.distanceMeters),
                start: activity.startedAt,
                end: endedAt
            )
            try await builder.addSamples([sample])
        }

        // Route pairing: retrieve the route's series builder FROM the
        // workout builder — it auto-associates and auto-finishes when the
        // workout builder finishes. Verified against HKWorkoutBuilder.h's
        // own doc comment: HKWorkoutRouteBuilder.finishRoute(with:) is
        // explicitly documented as "you should never call this method" when
        // the route builder is paired with a workout builder like this — a
        // trap the API's shape makes easy to fall into by copying the
        // standalone-route-builder pattern instead.
        if let routeBuilder = builder.seriesBuilder(for: HKSeriesType.workoutRoute()) as? HKWorkoutRouteBuilder {
            let locations = activity.routePoints.map {
                CLLocation(
                    coordinate: CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude),
                    altitude: $0.altitudeMeters,
                    horizontalAccuracy: $0.horizontalAccuracyMeters,
                    verticalAccuracy: $0.verticalAccuracyMeters,
                    timestamp: $0.recordedAt
                )
            }
            if !locations.isEmpty {
                try await routeBuilder.insertRouteData(locations)
            }
        }

        try await builder.endCollection(at: endedAt)
        guard let workout = try await builder.finishWorkout() else { return nil }

        // Stamp BEFORE returning, matching sync(_:)'s comment: a later
        // failure elsewhere must never cause a duplicate write on retry.
        activity.healthKitUUID = workout.uuid
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

    /// Steps per day for the last `days` days, keyed "yyyy-MM-dd", ending
    /// today.
    ///
    /// Days Health has nothing for are absent rather than zero — a coach
    /// reading a chart needs "no data" and "did not move" to look different,
    /// and HealthKit reports an empty bucket for both.
    func dailyStepCounts(days: Int) async throws -> [String: Int] {
        guard isAvailable, days > 0,
              let type = HKQuantityType.quantityType(forIdentifier: .stepCount) else { return [:] }

        let calendar = Calendar.current
        let endOfToday = calendar.startOfDay(for: .now)
        guard let start = calendar.date(byAdding: .day, value: -(days - 1), to: endOfToday)
        else { return [:] }

        let predicate = HKQuery.predicateForSamples(withStart: start, end: .now)
        let descriptor = HKStatisticsCollectionQueryDescriptor(
            predicate: .quantitySample(type: type, predicate: predicate),
            options: .cumulativeSum,
            // Anchoring to a day boundary is what makes each bucket a calendar
            // day rather than a rolling 24 hours from whenever this ran.
            anchorDate: start,
            intervalComponents: DateComponents(day: 1)
        )

        let collection = try await descriptor.result(for: store)
        var counts: [String: Int] = [:]
        for statistics in collection.statistics() {
            guard let sum = statistics.sumQuantity()?.doubleValue(for: .count()), sum > 0
            else { continue }
            counts[DayKey.make(from: statistics.startDate)] = Int(sum.rounded())
        }
        return counts
    }
}
