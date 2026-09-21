import Foundation
import HealthKit
import LiftKit

/// The live `HKWorkoutSession` for a lifting session: wrist-down runtime
/// while the watch is in a pocket between sets, heart rate on the Now screen,
/// and the workout itself written to HealthKit when it ends.
///
/// `OutdoorActivityRecorder` runs a session for a run and deliberately does
/// **not** use `HKLiveWorkoutBuilder`, because it computes distance and
/// elevation from the route points it collects itself and needs no live
/// statistics. This class is the opposite case and so makes the opposite
/// choice: the numbers it exists to show — current, average and maximum
/// heart rate — are exactly what the builder surfaces, and the builder is
/// also what saves the workout together with the samples collected during
/// it. Writing our own heart-rate samples into a second store is what the
/// design spec rules out, so the builder is the right tool here and the
/// wrong one there.
///
/// Only one `HKWorkoutSession` may be live at a time on watchOS. A run and a
/// lift cannot overlap in the UI — `RootView` gives an in-progress outdoor
/// recording the whole screen — so this never competes with the outdoor
/// recorder for that slot, and `start()` is a no-op if a session is somehow
/// already running here.
@MainActor
final class LiftingSessionRecorder: NSObject, ObservableObject {

    /// The most recent beat rate the builder has collected, `nil` until the
    /// first sample lands — which is a real state, not a zero. A watch
    /// simulator never produces one at all.
    @Published private(set) var currentBpm: Double?
    @Published private(set) var averageBpm: Double?
    @Published private(set) var maxBpm: Double?
    @Published private(set) var isRunning = false
    @Published private(set) var lastError: Error?

    private let healthStore = HKHealthStore()
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?

    /// Starts a strength-training session. Safe to call when HealthKit is
    /// unavailable or authorization is refused: the lifting session itself
    /// does not depend on it — sets are logged into the `WorkoutDraft`
    /// either way — so a failure here costs the heart rate and the
    /// background runtime, not the workout.
    func start() {
        guard session == nil, HKHealthStore.isHealthDataAvailable() else { return }
        currentBpm = nil
        averageBpm = nil
        maxBpm = nil
        lastError = nil
        let startDate = Date()
        Task { [weak self] in
            await self?.begin(at: startDate)
        }
    }

    /// Ends the session, hands the workout to HealthKit, and returns what to
    /// send the phone. `nil` when no heart rate was ever collected — the
    /// envelope then omits the key entirely rather than reporting a zero
    /// anyone could mistake for a measurement.
    @discardableResult
    func finish() -> SessionHeartRate? {
        guard let session, let builder else { return nil }
        let endDate = Date()
        let summary = heartRateSummary

        session.stopActivity(with: endDate)
        session.end()

        // The save outlives this call deliberately: `finishWorkout()` is what
        // writes the workout and the samples collected during it, and the
        // user has already moved on to the summary screen by now.
        Task {
            do {
                try await builder.endCollection(at: endDate)
                _ = try await builder.finishWorkout()
            } catch {
                await MainActor.run { self.lastError = error }
            }
        }

        self.session = nil
        self.builder = nil
        isRunning = false
        return summary
    }

    /// Ends the session and saves nothing — for a workout abandoned rather
    /// than finished.
    func discard() {
        guard let session, let builder else { return }
        session.stopActivity(with: Date())
        session.end()
        builder.discardWorkout()
        self.session = nil
        self.builder = nil
        isRunning = false
        currentBpm = nil
        averageBpm = nil
        maxBpm = nil
    }

    var heartRateSummary: SessionHeartRate? {
        guard let averageBpm, let maxBpm, averageBpm > 0, maxBpm > 0 else { return nil }
        return SessionHeartRate(averageBpm: averageBpm, maxBpm: maxBpm)
    }

    // MARK: - Starting

    private func begin(at startDate: Date) async {
        do {
            // Share the workout, read the heart rate. Both usage strings are
            // in the Info.plist already; the read set is what the live data
            // source needs permission for, and requesting it here means the
            // one system sheet covers the whole session.
            try await healthStore.requestAuthorization(
                toShare: [HKObjectType.workoutType()],
                read: [
                    HKQuantityType(.heartRate),
                    HKQuantityType(.activeEnergyBurned)
                ]
            )

            // `requestAuthorization` is an unbounded await on a system sheet.
            // If the workout was finished or abandoned while it was in
            // flight, creating a session now would leave one live forever —
            // watchOS allows exactly one, so every later start would quietly
            // fail. Same guard, for the same reason, as
            // `OutdoorActivityRecorder.startWorkoutSession`.
            guard session == nil else { return }

            let configuration = HKWorkoutConfiguration()
            configuration.activityType = .traditionalStrengthTraining
            configuration.locationType = .indoor

            let newSession = try HKWorkoutSession(healthStore: healthStore, configuration: configuration)
            let newBuilder = newSession.associatedWorkoutBuilder()
            newBuilder.dataSource = HKLiveWorkoutDataSource(
                healthStore: healthStore, workoutConfiguration: configuration
            )
            newSession.delegate = self
            newBuilder.delegate = self

            session = newSession
            builder = newBuilder

            newSession.startActivity(with: startDate)
            try await newBuilder.beginCollection(at: startDate)
        } catch {
            lastError = error
            // A half-built session is worse than none: it holds the one slot
            // watchOS allows without ever delivering a sample.
            session = nil
            builder = nil
            isRunning = false
        }
    }

    fileprivate func absorb(_ statistics: HKStatistics?) {
        guard let statistics, statistics.quantityType == HKQuantityType(.heartRate) else { return }
        let beatsPerMinute = HKUnit.count().unitDivided(by: .minute())
        currentBpm = statistics.mostRecentQuantity()?.doubleValue(for: beatsPerMinute)
        averageBpm = statistics.averageQuantity()?.doubleValue(for: beatsPerMinute)
        maxBpm = statistics.maximumQuantity()?.doubleValue(for: beatsPerMinute)
    }
}

// MARK: - HKWorkoutSessionDelegate

extension LiftingSessionRecorder: HKWorkoutSessionDelegate {

    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didChangeTo toState: HKWorkoutSessionState,
        from fromState: HKWorkoutSessionState,
        date: Date
    ) {
        Task { @MainActor in
            switch toState {
            case .running:        self.isRunning = true
            case .ended, .stopped: self.isRunning = false
            default:              break
            }
        }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        Task { @MainActor in self.lastError = error }
    }
}

// MARK: - HKLiveWorkoutBuilderDelegate

extension LiftingSessionRecorder: HKLiveWorkoutBuilderDelegate {

    nonisolated func workoutBuilder(
        _ workoutBuilder: HKLiveWorkoutBuilder,
        didCollectDataOf collectedTypes: Set<HKSampleType>
    ) {
        let heartRate = HKQuantityType(.heartRate)
        guard collectedTypes.contains(heartRate) else { return }
        Task { @MainActor in
            self.absorb(workoutBuilder.statistics(for: heartRate))
        }
    }

    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}
}
