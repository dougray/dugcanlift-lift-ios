import CoreLocation
import Foundation
import HealthKit
import LiftKit

/// Owns the live GPS recording for a Run or Hike on the watch: an
/// `HKWorkoutSession` to keep the app's sensors — GPS chief among them —
/// running efficiently while the screen is off or another app is
/// foregrounded, plus this app's own `CLLocationManager` to actually collect
/// the route. This is the same split `lift-ios`'s `LocationTracker` has with
/// the phone's location manager, except on watchOS the live workout session
/// has always managed background GPS this way — unlike the phone, which
/// only gets an OS-managed live session in iOS 26 (see the design spec's
/// correction in `docs/superpowers/specs/2026-09-07-route-recording-design.md`).
///
/// This class deliberately does not use `HKLiveWorkoutBuilder`. The builder
/// exists to surface live workout *statistics* (heart rate, active energy,
/// distance computed by the OS from its own quantity samples) as the
/// workout progresses. This app needs none of that: distance/elevation are
/// computed here, directly from the `RoutePoint`s this class collects
/// itself (see `OutdoorActivity.appendPoint(_:)`), and no heart-rate/energy
/// samples are streamed. The session's only job here is what the design
/// spec says its value is on watch: keeping GPS/sensors alive efficiently
/// in the background. Confirmed against the real watchOS SDK headers
/// (`HKWorkoutSession.h` in Xcode's WatchSimulator SDK) rather than assumed
/// from memory — see the task report for the exact API shape found.
@MainActor
final class OutdoorActivityRecorder: NSObject, ObservableObject {

    @Published private(set) var activity: OutdoorActivity?
    @Published private(set) var isRecording = false
    @Published private(set) var elapsedSeconds: TimeInterval = 0
    @Published private(set) var distanceMeters: Double = 0
    @Published private(set) var elevationGainMeters: Double = 0
    @Published private(set) var authorizationStatus: CLAuthorizationStatus
    @Published private(set) var lastError: Error?

    /// Average pace, in seconds per kilometer. `nil` until some distance has
    /// been recorded. Matches this codebase's `WeightUnit` convention of
    /// leaving unit *display* (km/mi here, kg/lb there) to the view layer —
    /// this only hands over the canonical metric number.
    var averagePaceSecondsPerKilometer: Double? {
        guard distanceMeters > 0 else { return nil }
        return elapsedSeconds / (distanceMeters / 1000)
    }

    private let healthStore = HKHealthStore()
    private let locationManager = CLLocationManager()
    private var session: HKWorkoutSession?
    private var tickTimer: Timer?
    private var recordingStartDate: Date?

    override init() {
        authorizationStatus = locationManager.authorizationStatus
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.activityType = .fitness
        // Distance-based filtering, not time-based — matches lift-ios's
        // LocationTracker and the Android tracker exactly, for cross-platform
        // consistency: a stationary watch should not accumulate noise points
        // while paused at a light.
        locationManager.distanceFilter = 5
        // NOTE: `pausesLocationUpdatesAutomatically` and
        // `showsBackgroundLocationIndicator`, which lift-ios's LocationTracker
        // sets, are both API_UNAVAILABLE(watchos) — confirmed against the real
        // CLLocationManager.h header, not assumed. They are intentionally
        // omitted here rather than ported.
    }

    // MARK: - Lifecycle

    /// Starts a new recording. No-op if one is already in progress.
    func start(type: OutdoorActivityType) {
        guard activity == nil else { return }

        let startDate = Date()
        activity = OutdoorActivity(activityType: type, startedAt: startDate)
        distanceMeters = 0
        elevationGainMeters = 0
        elapsedSeconds = 0
        lastError = nil
        recordingStartDate = startDate
        startTicking()

        // Location collection starts immediately and does not wait on
        // HealthKit authorization — watchOS has no
        // requestWhenInUseAuthorization/requestAlwaysAuthorization (confirmed
        // absent for watchos in the real CLLocationManager.h header); the
        // system presents its location prompt automatically on this first
        // call to startUpdatingLocation(), driven by the
        // NSLocationWhenInUseUsageDescription Info.plist key. The workout
        // session is started separately, in parallel, once HealthKit
        // authorization resolves. If that fails or is denied, the location
        // updates already flowing keep the recording itself working — the
        // session only makes background GPS more power-efficient, it is not
        // the source of the route data.
        locationManager.allowsBackgroundLocationUpdates = true
        locationManager.startUpdatingLocation()

        Task { [weak self] in
            await self?.startWorkoutSession(type: type, startDate: startDate)
        }
    }

    /// Ends the recording and returns the finished activity, or `nil` if
    /// nothing was being recorded. Callers only expose "Finish" while
    /// `isRecording`/`activity` is non-nil, but an optional return is a
    /// trivially cheap defense against that misuse rather than a crash.
    ///
    /// Deliberately does *not* end the `HKWorkoutSession` — only the
    /// location-manager half of teardown happens here (GPS is no longer
    /// needed once the activity is finished). The session must keep running
    /// until the HealthKit export attempt completes (success or failure), so
    /// the app retains background runtime through the export; callers finish
    /// that with `endHealthKitSession(at:)` once the export settles. See
    /// `OutdoorActivityView.finish()` for the full sequencing and why.
    @discardableResult
    func finish() -> OutdoorActivity? {
        guard var current = activity else { return nil }
        let endDate = Date()
        current.finish(at: endDate)
        activity = current
        teardownLocation()
        isRecording = false
        return current
    }

    /// Ends the recording and discards it — no finished `OutdoorActivity` is
    /// produced or returned. No export happens on this path, so both halves
    /// of teardown (location + session) happen immediately, same as before.
    func discard() {
        guard activity != nil else { return }
        teardownLocation()
        endHealthKitSession(at: Date())
        isRecording = false
        activity = nil
    }

    /// Clears `activity` back to `nil` without touching the location manager
    /// or the workout session — used after `finish()` once the caller has
    /// captured the returned snapshot, so `RootView` routes back to the start
    /// screen immediately while the session (already left running by
    /// `finish()`) stays alive for the in-flight HealthKit export.
    func resetAfterFinish() {
        activity = nil
    }

    private func teardownLocation() {
        tickTimer?.invalidate()
        tickTimer = nil
        recordingStartDate = nil
        locationManager.stopUpdatingLocation()
        locationManager.allowsBackgroundLocationUpdates = false
    }

    /// Ends the `HKWorkoutSession` — safe to call even if `session` is
    /// already `nil` (no-op). Split out from location teardown so the
    /// session can be kept alive until a HealthKit export attempt (success
    /// or failure) completes; see `finish()`'s doc comment.
    func endHealthKitSession(at endDate: Date) {
        session?.stopActivity(with: endDate)
        session?.end()
        session = nil
    }

    // MARK: - HealthKit

    private func startWorkoutSession(type: OutdoorActivityType, startDate: Date) async {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        do {
            // Requests the same full share set HealthKitExporter needs at
            // export time (workout type, route series, distance quantity)
            // rather than just workoutType() — so the one system permission
            // sheet shown across a Start→Finish cycle covers everything;
            // HealthKitExporter.requestExportAuthorization's own call later
            // becomes a redundant-but-harmless no-op once these are granted
            // (HealthKit doesn't re-prompt for already-authorized types).
            try await healthStore.requestAuthorization(toShare: HealthKitExporter.requiredShareTypes(), read: [])

            // requestAuthorization is an unbounded await on a system sheet.
            // If finish()/discard() ran while it was in flight, `activity`
            // is now nil (or a different recording started), and creating a
            // session here would leak it live forever — watchOS allows only
            // one active HKWorkoutSession, so every subsequent start(type:)
            // would silently fail until the app relaunches. Re-verify this
            // is still the same in-flight recording before proceeding.
            guard activity?.startedAt == startDate, session == nil else { return }

            let configuration = HKWorkoutConfiguration()
            configuration.activityType = hkActivityType(for: type)
            configuration.locationType = .outdoor

            // The non-deprecated initializer as of watchOS 5.0 (confirmed in
            // HKWorkoutSession.h): initWithHealthStore:configuration:error:,
            // NOT the older initWithConfiguration:error:/
            // initWithActivityType:locationType: — both of those are
            // API_DEPRECATED on watchOS.
            let newSession = try HKWorkoutSession(healthStore: healthStore, configuration: configuration)
            newSession.delegate = self

            // Re-check once more right before committing to a session: the
            // synchronous work above (creating the configuration/session) is
            // not itself an await point, but this second guard costs nothing
            // and keeps the invariant airtight against future changes to
            // this method that might add one.
            guard activity?.startedAt == startDate, session == nil else { return }

            session = newSession
            newSession.prepare()
            newSession.startActivity(with: startDate)
        } catch {
            lastError = error
        }
    }

    private func hkActivityType(for type: OutdoorActivityType) -> HKWorkoutActivityType {
        switch type {
        case .run: return .running
        case .hike: return .hiking
        }
    }

    // MARK: - Ticking

    /// Elapsed time has no OS-provided live source here (that is exactly
    /// what `HKLiveWorkoutBuilder` would otherwise hand over, and this class
    /// deliberately doesn't use it) — so a plain one-second repeating timer
    /// derives it from the wall-clock start date instead.
    private func startTicking() {
        tickTimer?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateElapsed() }
        }
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    private func updateElapsed() {
        guard let recordingStartDate else { return }
        elapsedSeconds = Date().timeIntervalSince(recordingStartDate)
    }

    // MARK: - Route collection

    private func appendLocation(_ location: CLLocation) {
        guard var current = activity else { return }
        let point = RoutePoint(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            altitudeMeters: location.altitude,
            recordedAt: location.timestamp,
            horizontalAccuracyMeters: location.horizontalAccuracy,
            verticalAccuracyMeters: location.verticalAccuracy
        )
        // appendPoint(_:) owns the incremental distance / recomputed
        // elevation-gain design — see its doc comment in OutdoorActivity.swift
        // for why those two are handled differently.
        guard current.appendPoint(point) else { return }
        activity = current
        distanceMeters = current.distanceMeters
        elevationGainMeters = current.elevationGainMeters
    }
}

// MARK: - CLLocationManagerDelegate

extension OutdoorActivityRecorder: CLLocationManagerDelegate {

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in self.authorizationStatus = status }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        // Same quality filter as lift-ios's LocationTracker and the Android
        // tracker tonight: reject invalid/stale/inaccurate fixes before they
        // ever become a RoutePoint. CoreLocation's first delivered location is
        // routinely a stale cached fix, and a negative horizontalAccuracy
        // means the coordinate itself is invalid.
        let goodLocations = locations.filter {
            $0.horizontalAccuracy >= 0 &&
            $0.horizontalAccuracy <= 50 &&
            abs($0.timestamp.timeIntervalSinceNow) <= 5
        }
        guard !goodLocations.isEmpty else { return }
        Task { @MainActor in
            for location in goodLocations {
                self.appendLocation(location)
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.lastError = error }
    }
}

// MARK: - HKWorkoutSessionDelegate

extension OutdoorActivityRecorder: HKWorkoutSessionDelegate {

    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didChangeTo toState: HKWorkoutSessionState,
        from fromState: HKWorkoutSessionState,
        date: Date
    ) {
        Task { @MainActor in
            switch toState {
            case .running:
                self.isRecording = true
            case .ended, .stopped:
                self.isRecording = false
            default:
                break
            }
        }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        Task { @MainActor in self.lastError = error }
    }
}
