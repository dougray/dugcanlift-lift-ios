import Foundation
import HealthKit
import WatchConnectivity
import LiftSync

// Path B, the phone's side: heart rate from LIFT on the Apple Watch, live,
// during a run the phone records.
//
// The phone asks the watch to start (`HKHealthStore.startWatchApp(toHandle:)`);
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
@MainActor
protocol WatchHeartRateLinking: AnyObject {
    /// Asks the watch to start measuring. Throws when it cannot be asked (not
    /// reachable, not installed); a watch that starts but never sends is not
    /// an error, only a run with no live number.
    func start() async throws
    /// Ends the watch's session. Safe at any time, and more than once.
    func stop()
    /// Each reading, on the main actor.
    var onReading: (@MainActor (Int, Date) -> Void)? { get set }
}

/// What a run does with the watch once it has asked it to start.
enum WatchLinkStart {
    /// The watch is the run's source only when it could be asked. A failure is
    /// no live source at all -- never a strap or Health swapped in -- and Health
    /// fills the summary after the run, as for any run no source spoke for.
    static func source(started: Bool) -> LiveHeartRateSource? {
        started ? .watch : nil
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

    var onReading: (@MainActor (Int, Date) -> Void)?

    private let healthStore = HKHealthStore()
    /// The session the watch mirrored here, while a run listens to it.
    private var mirrored: HKWorkoutSession?
    /// Whether a run wants the watch: true from `start()` to `stop()`.
    private var wanted = false
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

    func start() async throws {
        install()
        wanted = true
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .running
        configuration.locationType = .outdoor
        do {
            try await healthStore.startWatchApp(toHandle: configuration)
        } catch {
            wanted = false
            throw error
        }
    }

    func stop() {
        wanted = false
        onReading = nil
        guard let mirrored else { return }
        self.mirrored = nil
        // Ending the mirrored session ends the watch's, which discards its
        // workout: the phone's is the one that goes to Health.
        mirrored.end()
    }

    private func received(_ session: HKWorkoutSession) {
        switch WatchMirrorDecision.decide(runWantsWatch: wanted) {
        case .adopt:
            if let mirrored, mirrored !== session { mirrored.delegate = nil }
            session.delegate = self
            mirrored = session
        case .end:
            session.end()
        }
    }

    private func deliver(_ readings: [RunHeartRatePayload], from session: HKWorkoutSession) {
        guard session === mirrored, let onReading else { return }
        for reading in readings { onReading(reading.bpm, reading.at) }
    }

    private func lost(_ session: HKWorkoutSession) {
        // The watch ended (its own run or lift took the session, or it gave up
        // on a phone it could not reach). The run keeps the watch as its source
        // and shows no number; nothing else is swapped in.
        guard session === mirrored else { return }
        mirrored = nil
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
        guard toState == .ended else { return }
        Task { @MainActor [weak self] in self?.lost(workoutSession) }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {}

    /// The watch tries the phone again a few times (`RunHeartRateRelayPolicy`),
    /// and a reconnect arrives as a new mirrored session, adopted above.
    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession,
                                    didDisconnectFromRemoteDeviceWithError error: Error?) {}
}
