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
    @discardableResult
    func finish() -> OutdoorActivity? {
        guard var current = activity else { return nil }
        let endDate = Date()
        current.finish(at: endDate)
        activity = current
        teardown(endDate: endDate)
        return current
    }

    /// Ends the recording and discards it — no finished `OutdoorActivity` is
    /// produced or returned.
    func discard() {
        guard activity != nil else { return }
        teardown(endDate: Date())
        activity = nil
    }

    private func teardown(endDate: Date) {
        tickTimer?.invalidate()
        tickTimer = nil
        recordingStartDate = nil
        locationManager.stopUpdatingLocation()
        locationManager.allowsBackgroundLocationUpdates = false
        session?.stopActivity(with: endDate)
        session?.end()
        session = nil
        isRecording = false
    }

    // MARK: - HealthKit

    private func startWorkoutSession(type: OutdoorActivityType, startDate: Date) async {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        do {
            // Only share authorization for the workout type itself is
            // requested: per this type's doc comment, this recorder never
            // reads Health data and never streams live heart-rate/energy
            // samples through a builder, so there is nothing else to ask for.
            try await healthStore.requestAuthorization(toShare: [HKObjectType.workoutType()], read: [])

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
