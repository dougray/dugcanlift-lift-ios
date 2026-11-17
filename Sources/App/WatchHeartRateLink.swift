import Foundation
import HealthKit
import WatchConnectivity
import LiftSync

// Path B, the phone's side: heart rate from LIFT on the Apple Watch, live,
// during a run the phone records.
//
// The phone asks the watch to start (`HKHealthStore.startWatchApp(with:completion:)`);
// the watch runs a workout session that measures heart rate, mirrors it here,
// and sends each reading as a `RunHeartRatePayload`. The phone keeps the run
// and exports it; the watch saves nothing. Tracked and shown, never targeted.
//
// The decisions are values below, tested without a watch; `WatchHeartRateLink`
// is the HealthKit wiring around them.

/// Whether LIFT's watch app can measure a run: a watch is paired and LIFT is
/// installed on it, read from the app's one `WCSession`.
@MainActor
protocol WatchAvailability {
    var isWatchAppReady: Bool { get }
}

enum WatchAvailabilityRule {
    /// Ready only with a session that is up, a paired watch, LIFT installed on
    /// it, and Health on this phone. `isPaired` and `isWatchAppInstalled` mean
    /// nothing before the session activates, so not activated is not ready.
    static func ready(supported: Bool, activated: Bool, paired: Bool, installed: Bool, healthAvailable: Bool) -> Bool {
        supported && activated && paired && installed && healthAvailable
    }
}

/// The real one. It reads `WCSession.default` and never activates it or takes
/// its delegate: `WatchSyncReceiver` owns the app's one session (activated
/// from `LiftApp.init`), and WatchConnectivity allows a single delegate.
struct PairedWatchAvailability: WatchAvailability {
    var isWatchAppReady: Bool {
        let supported = WCSession.isSupported()
        let session = supported ? WCSession.default : nil
        return WatchAvailabilityRule.ready(
            supported: supported,
            activated: session?.activationState == .activated,
            paired: session?.isPaired ?? false,
            installed: session?.isWatchAppInstalled ?? false,
            healthAvailable: HKHealthStore.isHealthDataAvailable())
    }
}

/// Where Settings shows the Apple Watch row.
enum HeartRateWatchRow {
    /// When the watch can measure a run, and also while it is the chosen
    /// setting, so a person whose watch is away still sees what they chose.
    static func shows(ready: Bool, setting: HeartRateSetting) -> Bool {
        ready || setting == .watch
    }
}

/// The watch, as `ActiveRun` uses it. `WatchHeartRateLink` is the real one.
///
/// Every call names its run, so a late answer from a run that is over can
/// never start or stop the watch for the run after it.
@MainActor
protocol WatchHeartRateLinking: AnyObject {
    /// Asks the watch to start measuring for `run`. Throws when it cannot be
    /// asked or did not launch; a watch that starts but never sends is not an
    /// error, only a run with no live number.
    func start(run: UUID) async throws
    /// Ends the watch's session for `run`. A no-op for any run but the one the
    /// watch is measuring; safe at any time, and more than once.
    func stop(run: UUID)
    /// Each reading, on the main actor.
    var onReading: (@MainActor (Int, Date) -> Void)? { get set }
}

/// Which run the watch is measuring for, if any.
struct WatchLinkRuns: Equatable {
    private(set) var current: UUID?

    var wantsWatch: Bool { current != nil }

    mutating func began(_ run: UUID) {
        current = run
    }

    /// True when `run` was the one being measured, so the stop acts. A stale
    /// stop from a run that is over changes nothing.
    mutating func stop(_ run: UUID) -> Bool {
        guard current == run else { return false }
        current = nil
        return true
    }
}

/// What a run does with the watch once it has asked it to start.
enum WatchLinkStart {
    struct DidNotLaunch: Error {}

    /// The watch is the run's source only when it could be asked. A failure is
    /// no live source at all -- never a strap or Health swapped in -- and Health
    /// fills the summary after the run, as for any run no source spoke for.
    static func source(started: Bool) -> LiveHeartRateSource? {
        started ? .watch : nil
    }

    /// `startWatchApp`'s answer: started only on success with no error. A
    /// `false` with no error is still a watch that did not launch, so the run
    /// does not show "from Apple Watch" for a watch that never heard it.
    static func failure(success: Bool, error: Error?) -> Error? {
        if let error { return error }
        return success ? nil : DidNotLaunch()
    }
}

/// What the link does with a mirrored session HealthKit hands it.
enum WatchMirrorDecision: Equatable {
    /// A run asked for it: listen to it (again, after the watch reconnected).
    case adopt
    /// Nobody asked, or the run is over: end it, which ends the watch's
    /// session and discards its workout, so nothing is left running there.
    case end

    static func decide(runWantsWatch: Bool) -> WatchMirrorDecision {
        runWantsWatch ? .adopt : .end
    }
}

@MainActor
final class WatchHeartRateLink: NSObject, WatchHeartRateLinking {
    static let shared = WatchHeartRateLink()

    /// How long a closing session waits for its `stop` to be sent before it is
    /// ended anyway.
    static let closeGrace: Duration = .seconds(2)

    var onReading: (@MainActor (Int, Date) -> Void)?

    private let healthStore = HKHealthStore()
    /// The session the watch mirrored here, while a run listens to it.
    private var mirrored: HKWorkoutSession?
    private var runs = WatchLinkRuns()
    private var installed = false

    /// Installs the mirroring handler. Called once, from `LiftApp.init`:
    /// HealthKit says to set it promptly at launch, because a watch that
    /// mirrors to a phone app that is not running launches it in the
    /// background, and the handler is how that session is heard -- and ended,
    /// when no run wants it, so a watch is never left measuring for nobody.
    func install() {
        guard !installed, HKHealthStore.isHealthDataAvailable() else { return }
        installed = true
        // HealthKit calls this on a background queue.
        healthStore.workoutSessionMirroringStartHandler = { [weak self] session in
            Task { @MainActor in self?.received(session) }
        }
    }

    func start(run: UUID) async throws {
        install()
        runs.began(run)
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .running
        configuration.locationType = .outdoor
        do {
            // The completion form, so a `false` with no error is a failure
            // decided here (`WatchLinkStart.failure`), not left to the bridge.
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                healthStore.startWatchApp(with: configuration) { success, error in
                    if let failure = WatchLinkStart.failure(success: success, error: error) {
                        continuation.resume(throwing: failure)
                    } else {
                        continuation.resume()
                    }
                }
            }
        } catch {
            _ = runs.stop(run)
            throw error
        }
    }

    func stop(run: UUID) {
        guard runs.stop(run) else { return }
        onReading = nil
        guard let mirrored else { return }
        self.mirrored = nil
        close(mirrored)
    }

    /// Ends a mirrored session three ways, so the watch ends its relay and
    /// discards its workout even if one of them never reaches it: a `stop`
    /// command, `stopActivity`, then `end()`. The phone's workout is the one
    /// that goes to Health.
    private func close(_ session: HKWorkoutSession) {
        session.delegate = nil
        let closing = Closing(session)
        if let data = try? RunHeartRateCommand.stop.encoded() {
            session.sendToRemoteWorkoutSession(data: data) { _, _ in
                Task { @MainActor in closing.end() }
            }
        }
        session.stopActivity(with: .now)
        Task { @MainActor in
            try? await Task.sleep(for: Self.closeGrace)
            closing.end()
        }
    }

    private func received(_ session: HKWorkoutSession) {
        switch WatchMirrorDecision.decide(runWantsWatch: runs.wantsWatch) {
        case .adopt:
            if let mirrored, mirrored !== session { mirrored.delegate = nil }
            session.delegate = self
            mirrored = session
        case .end:
            close(session)
        }
    }

    private func deliver(_ readings: [RunHeartRatePayload], from session: HKWorkoutSession) {
        guard session === mirrored, let onReading else { return }
        for reading in readings { onReading(reading.bpm, reading.at) }
    }

    private func lost(_ session: HKWorkoutSession) {
        // The watch ended or failed (its own run or lift took the session, or
        // it gave up on a phone it could not reach). The run keeps the watch as
        // its source and shows no number; nothing else is swapped in.
        guard session === mirrored else { return }
        mirrored = nil
    }
}

/// Ends a session once, whichever of the `stop` send or the grace period comes
/// first.
@MainActor
private final class Closing {
    private let session: HKWorkoutSession
    private var done = false

    init(_ session: HKWorkoutSession) { self.session = session }

    func end() {
        guard !done else { return }
        done = true
        session.end()
    }
}

extension WatchHeartRateLink: HKWorkoutSessionDelegate {
    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession,
                                    didReceiveDataFromRemoteWorkoutSession data: [Data]) {
        // Decoded here, off the main actor; anything that is not a reading
        // (garbage, a zero) is dropped, never a crash.
        let readings = RunHeartRatePayload.decodeAll(data)
        guard !readings.isEmpty else { return }
        Task { @MainActor [weak self] in self?.deliver(readings, from: workoutSession) }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession,
                                    didChangeTo toState: HKWorkoutSessionState,
                                    from fromState: HKWorkoutSessionState, date: Date) {
        guard toState == .ended || toState == .stopped else { return }
        Task { @MainActor [weak self] in self?.lost(workoutSession) }
    }

    /// A failed session is a lost one, as an ended one is.
    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        Task { @MainActor [weak self] in self?.lost(workoutSession) }
    }

    /// The watch tries the phone again after 2, 5 and 10 seconds
    /// (`RunHeartRateRelayPolicy`), and a reconnect arrives as a mirrored
    /// session, adopted above.
    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession,
                                    didDisconnectFromRemoteDeviceWithError error: Error?) {}
}
