import Foundation
import HealthKit
import LiftKit
import LiftSync

/// Path B: heart rate for a run the **phone** records, measured here and sent
/// to the phone live.
///
/// The phone calls `HKHealthStore.startWatchApp(toHandle:)`, which launches or
/// wakes this app and calls `LiftWatchAppDelegate.handle(_:)` with the
/// configuration; that calls `start`. The relay runs an `HKWorkoutSession`
/// with an `HKLiveWorkoutBuilder` that collects heart rate and nothing else,
/// mirrors the session to the phone (`startMirroringToCompanionDevice`), and
/// sends each new heart rate statistic as a `RunHeartRatePayload` with
/// `sendToRemoteWorkoutSession(data:)`.
///
/// **It saves nothing.** The phone exports the run, so when the session ends
/// -- the phone's Finish or Cancel ends the mirrored session, which ends this
/// one -- the builder's workout is discarded: one workout in Health, the
/// phone's, never two. Nothing is stored here and no reading is kept.
///
/// **GPS stays off.** The phone asks for an outdoor run, but the session here
/// is configured indoor: the phone records the route, and an outdoor session
/// would have the watch work out a distance it then throws away.
///
/// **The watch's own recordings come first.** It does not touch
/// `OutdoorActivityRecorder` or `LiftingSessionRecorder`: it does not start
/// while either is going (`isWatchBusy`), and either one starting calls
/// `stop()` first, since watchOS allows one live workout session.
@MainActor
final class RunHeartRateRelay: NSObject {

    /// Whether the watch is recording a run or a lift of its own. Set once by
    /// `LiftWatchApp`, which owns both recorders.
    static var isWatchBusy: @MainActor () -> Bool = { false }

    static func start(_ configuration: HKWorkoutConfiguration) {
        shared.begin(configuration)
    }

    static func stop() {
        shared.end()
    }

    private static let shared = RunHeartRateRelay()

    private let healthStore = HKHealthStore()
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?
    /// Set while a start waits on HealthKit, so a second request in that
    /// window starts nothing and a `stop()` in it is heard.
    private var pendingStart: UUID?
    private var retries = 0

    private var relaying: Bool { session != nil || pendingStart != nil }

    private func begin(_ requested: HKWorkoutConfiguration) {
        guard HKHealthStore.isHealthDataAvailable(),
              RunHeartRateRelayPolicy.shouldStart(watchBusy: Self.isWatchBusy(), relaying: relaying)
        else { return }
        let token = UUID()
        pendingStart = token
        retries = 0
        Task { await self.run(requested, token: token) }
    }

    private func run(_ requested: HKWorkoutConfiguration, token: UUID) async {
        do {
            // The same two types `LiftingSessionRecorder` asks for, so a person
            // who has lifted with the watch sees no new sheet: sharing the
            // workout type is what lets a session run, and heart rate is what
            // the live data source reads. Nothing is ever written.
            try await healthStore.requestAuthorization(toShare: [HKObjectType.workoutType()],
                                                       read: [HKQuantityType(.heartRate)])
            // Stopped, or the watch started its own recording, while the sheet
            // was up: start nothing.
            guard pendingStart == token, session == nil, !Self.isWatchBusy() else {
                if pendingStart == token { pendingStart = nil }
                return
            }
            pendingStart = nil

            let configuration = HKWorkoutConfiguration()
            configuration.activityType = requested.activityType
            configuration.locationType = .indoor   // GPS off: the phone has the route

            let newSession = try HKWorkoutSession(healthStore: healthStore, configuration: configuration)
            let newBuilder = newSession.associatedWorkoutBuilder()
            let source = HKLiveWorkoutDataSource(healthStore: healthStore, workoutConfiguration: configuration)
            for type in source.typesToCollect
            where !RunHeartRateRelayPolicy.collectedTypeIdentifiers.contains(type.identifier) {
                source.disableCollection(for: type)
            }
            source.enableCollection(for: HKQuantityType(.heartRate), predicate: nil)
            newBuilder.dataSource = source
            newSession.delegate = self
            newBuilder.delegate = self
            session = newSession
            builder = newBuilder

            let startDate = Date()
            newSession.startActivity(with: startDate)
            try await newBuilder.beginCollection(at: startDate)
            if await !mirror(newSession) { ended(newSession) }
        } catch {
            // Not authorized, no session, or no phone: the phone's run goes on
            // with no live number and Health fills its summary afterwards.
            if pendingStart == token { pendingStart = nil }
            end()
        }
    }

    /// Mirrors the session to the phone. False when the phone cannot be
    /// reached, which ends the relay: a session no one hears is only a drain.
    private func mirror(_ mirrored: HKWorkoutSession) async -> Bool {
        let succeeded: Bool
        do {
            try await mirrored.startMirroringToCompanionDevice()
            succeeded = true
        } catch {
            succeeded = false
        }
        switch RunHeartRateRelayPolicy.afterMirroring(succeeded: succeeded) {
        case .keepRelaying:
            retries = 0
            return true
        case .mirrorAgain, .end:
            return false
        }
    }

    /// Ends the session and discards its workout. Safe to call at any time,
    /// including with nothing running.
    private func end() {
        pendingStart = nil
        guard let session else { return }
        let builder = self.builder
        self.session = nil
        self.builder = nil
        if session.state != .ended { session.end() }
        builder?.discardWorkout()
    }

    // MARK: - From HealthKit, on its queues

    private func ended(_ ended: HKWorkoutSession) {
        guard ended === session else { return }
        end()
    }

    private func disconnected(_ from: HKWorkoutSession) {
        guard from === session else { return }
        switch RunHeartRateRelayPolicy.afterDisconnect(retriesSoFar: retries) {
        case .mirrorAgain:
            retries += 1
            Task {
                if await !self.mirror(from) { self.ended(from) }
            }
        case .keepRelaying:
            break
        case .end:
            end()
        }
    }

    private func send(_ statistics: HKStatistics?, from builder: HKLiveWorkoutBuilder) {
        guard builder === self.builder, let session, let statistics,
              let quantity = statistics.mostRecentQuantity() else { return }
        let bpm = quantity.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))
        let at = statistics.mostRecentQuantityDateInterval()?.end ?? Date()
        guard let payload = RunHeartRatePayload.reading(bpm: bpm, at: at),
              let data = try? payload.encoded() else { return }
        // A reading that does not arrive is the one a reconnect replaces: the
        // phone hides a number ten seconds old on its own.
        session.sendToRemoteWorkoutSession(data: data) { _, _ in }
    }
}

// MARK: - HKWorkoutSessionDelegate

extension RunHeartRateRelay: HKWorkoutSessionDelegate {

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession,
                                    didChangeTo toState: HKWorkoutSessionState,
                                    from fromState: HKWorkoutSessionState, date: Date) {
        guard toState == .ended else { return }
        Task { @MainActor in self.ended(workoutSession) }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        Task { @MainActor in self.ended(workoutSession) }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession,
                                    didDisconnectFromRemoteDeviceWithError error: Error?) {
        Task { @MainActor in self.disconnected(workoutSession) }
    }

    /// The phone sends nothing; anything that arrives is ignored.
    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession,
                                    didReceiveDataFromRemoteWorkoutSession data: [Data]) {}
}

// MARK: - HKLiveWorkoutBuilderDelegate

extension RunHeartRateRelay: HKLiveWorkoutBuilderDelegate {

    nonisolated func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder,
                                    didCollectDataOf collectedTypes: Set<HKSampleType>) {
        let heartRate = HKQuantityType(.heartRate)
        guard collectedTypes.contains(heartRate) else { return }
        let statistics = workoutBuilder.statistics(for: heartRate)
        Task { @MainActor in self.send(statistics, from: workoutBuilder) }
    }

    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}
}
