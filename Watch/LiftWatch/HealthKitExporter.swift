import CoreLocation
import Foundation
import HealthKit
import LiftKit

/// Writes a finished `OutdoorActivity` to HealthKit via `HKWorkoutBuilder`/
/// `HKWorkoutRouteBuilder` — the actual persistence step nothing else in
/// this plan performs. `OutdoorActivityRecorder`'s `HKWorkoutSession` only
/// keeps GPS/sensors alive efficiently during a *live* recording; per its
/// own doc comment it "persists nothing to HealthKit on its own." This is
/// the missing write path Task 3's final review flagged.
///
/// Ported from `lift-ios`'s `HealthKitManager.exportOutdoorActivity(_:)` —
/// same builder sequence, same idempotency rule via `healthKitUUID` — with
/// two adaptations for this repo instead of a blind copy:
///
///   1. `lift-ios`'s `OutdoorActivity` is a SwiftData `final class`, so the
///      phone version mutates `activity.healthKitUUID` in place. This
///      repo's `OutdoorActivity` (`OutdoorActivity.swift`) is a value type
///      with every field `private(set)`, matching `WorkoutDraft`'s
///      convention. A value can't be mutated through a non-`inout`
///      parameter, so this returns the new `UUID` instead and leaves
///      stamping it to the caller via `OutdoorActivity.markExported(_:)` —
///      the same "return a value, caller re-assigns its own copy" shape
///      `finish(at:)` and `appendPoint(_:)` already use.
///   2. `OutdoorActivity`/`RoutePoint`'s field names
///      (`OutdoorActivityModels.swift`) already match `lift-ios`'s exactly
///      (`startedAt`/`endedAt: Date?`, `RoutePoint.recordedAt: Date`, etc.)
///      — no type/name conversion was needed, unlike the brief's own
///      speculative caveat about epoch-millisecond fields.
///
/// The builder call sequence itself was checked against this watchOS SDK's
/// real headers (`HKWorkoutBuilder.h`, `HKWorkoutRouteBuilder.h` in
/// `WatchSimulator26.5.sdk`), not assumed from the iOS-ported snippet:
/// every method used here (`beginCollection(at:)`, `addMetadata(_:)`,
/// `addSamples(_:)`, `seriesBuilder(for:)`, `insertRouteData(_:)`,
/// `endCollection(at:)`, `finishWorkout()`) is available on watchOS at or
/// below this app's watchOS 10.0 deployment target, and the route-pairing
/// approach matches `HKWorkoutRouteBuilder.h`'s own doc comment verbatim:
/// "If you are using this route builder with a workout builder, you
/// should never call [finishRouteWithWorkout:metadata:completion:] ...
/// The route will be finished when you finish the workout builder."
struct HealthKitExporter {

    private let healthStore: HKHealthStore

    init(healthStore: HKHealthStore) {
        self.healthStore = healthStore
    }

    /// The full set of share-access types this export path writes: the
    /// workout itself, its route series, and its distance quantity samples.
    /// HealthKit does not throw when a sample/series type lacks share
    /// authorization, it just silently drops that piece on save — so a
    /// caller requesting anything narrower than this (e.g.
    /// `OutdoorActivityRecorder.startWorkoutSession`, which used to request
    /// only `workoutType()` for its `HKWorkoutSession`) risks a workout
    /// landing in Health with no route and no distance and no error to
    /// notice the gap by. Confirmed against `HKWorkoutRouteBuilder.h`/
    /// `HKObjectType.h` — distance samples and route series data are each
    /// their own HealthKit-authorization-gated sample type, independent of
    /// the workout object's own authorization.
    ///
    /// Hoisted to a static helper so `OutdoorActivityRecorder` can request
    /// this same full set up front at `start(type:)` time, instead of a
    /// second permission sheet appearing later at export time (see the
    /// final-review fix wave's M3).
    static func requiredShareTypes() -> Set<HKSampleType> {
        var shareTypes: Set<HKSampleType> = [HKObjectType.workoutType(), HKSeriesType.workoutRoute()]
        if let distanceType = HKQuantityType.quantityType(forIdentifier: .distanceWalkingRunning) {
            shareTypes.insert(distanceType)
        }
        return shareTypes
    }

    /// Requests write access for everything this export path writes. Left
    /// in place (rather than removed) for `HealthKitExporter`'s own
    /// safety/testability in isolation — once `OutdoorActivityRecorder`
    /// requests the full set at `start(type:)` time, HealthKit doesn't
    /// re-prompt for already-authorized types, so this call becomes a
    /// redundant-but-harmless no-op in the live Start→Finish flow.
    private func requestExportAuthorization() async throws {
        try await healthStore.requestAuthorization(toShare: Self.requiredShareTypes(), read: [])
    }

    /// Writes `activity` to HealthKit and returns the new workout's `UUID`,
    /// or `nil` if there was nothing to export — already exported
    /// (`healthKitUUID != nil`) or not yet finished (`endedAt == nil`).
    ///
    /// Callers are responsible for persisting the returned UUID onto their
    /// own copy of the activity via `OutdoorActivity.markExported(_:)`
    /// before this could ever be called again for the same activity — this
    /// function cannot do that itself since `activity` is a value type.
    func exportOutdoorActivity(_ activity: OutdoorActivity) async throws -> UUID? {
        guard HKHealthStore.isHealthDataAvailable(),
              activity.healthKitUUID == nil,
              let endedAt = activity.endedAt else { return nil }

        try await requestExportAuthorization()

        let configuration = HKWorkoutConfiguration()
        configuration.activityType = activity.activityType == .run ? .running : .hiking
        configuration.locationType = .outdoor

        let builder = HKWorkoutBuilder(healthStore: healthStore, configuration: configuration, device: .local())
        try await builder.beginCollection(at: activity.startedAt)

        var metadata: [String: Any] = [HKMetadataKeyWorkoutBrandName: "Lift"]
        metadata["LiftElevationGainMeters"] = activity.elevationGainMeters
        try await builder.addMetadata(metadata)

        if let distanceType = HKQuantityType.quantityType(forIdentifier: .distanceWalkingRunning),
           activity.distanceMeters > 0 {
            let sample = HKCumulativeQuantitySample(
                type: distanceType,
                quantity: HKQuantity(unit: .meter(), doubleValue: activity.distanceMeters),
                start: activity.startedAt, end: endedAt
            )
            try await builder.addSamples([sample])
        }

        // Route pairing: retrieve the route's series builder FROM the
        // workout builder — it auto-associates and auto-finishes when the
        // workout builder finishes. HKWorkoutRouteBuilder.finishRoute(with:)
        // must never be called directly when paired with a workout builder
        // like this (verified against HKWorkoutRouteBuilder.h's own doc
        // comment on this watchOS SDK, not just assumed from the iOS port).
        if let routeBuilder = builder.seriesBuilder(for: HKSeriesType.workoutRoute()) as? HKWorkoutRouteBuilder {
            let locations = activity.routePoints.map {
                CLLocation(
                    coordinate: CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude),
                    altitude: $0.altitudeMeters, horizontalAccuracy: $0.horizontalAccuracyMeters,
                    verticalAccuracy: $0.verticalAccuracyMeters, timestamp: $0.recordedAt
                )
            }
            if !locations.isEmpty { try await routeBuilder.insertRouteData(locations) }
        }

        try await builder.endCollection(at: endedAt)
        guard let workout = try await builder.finishWorkout() else { return nil }
        return workout.uuid
    }
}
