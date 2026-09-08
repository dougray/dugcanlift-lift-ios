import CoreLocation
import Foundation
import Observation

/// Owns CoreLocation for outdoor activity recording. LIFT runs this itself
/// rather than relying on an OS-managed workout session — see the design
/// spec's correction: live GPS during a workout is a watchOS-only OS
/// capability below iOS 26. `HealthKitManager` only sees the result once
/// `stop()` has been called and the caller reads `points`.
@MainActor
@Observable
final class LocationTracker: NSObject {

    private let manager = CLLocationManager()

    private(set) var points: [RoutePoint] = []
    private(set) var isTracking = false
    private(set) var authorizationStatus: CLAuthorizationStatus

    override init() {
        authorizationStatus = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.activityType = .fitness
        // Distance-based filtering, not time-based: a stationary phone
        // should not accumulate noise points while paused at a light.
        manager.distanceFilter = 5
    }

    func requestAuthorization() {
        manager.requestAlwaysAuthorization()
    }

    func start() {
        points = []
        isTracking = true
        manager.allowsBackgroundLocationUpdates = true
        manager.pausesLocationUpdatesAutomatically = false
        manager.startUpdatingLocation()
    }

    func stop() {
        isTracking = false
        manager.allowsBackgroundLocationUpdates = false
        manager.stopUpdatingLocation()
    }
}

extension LocationTracker: CLLocationManagerDelegate {

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.authorizationStatus = status
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        // Filter out invalid/stale/inaccurate fixes before they ever become a
        // RoutePoint: CoreLocation's first delivered location is routinely a
        // stale cached fix, and a negative horizontalAccuracy means the
        // coordinate itself is invalid.
        let goodLocations = locations.filter {
            $0.horizontalAccuracy >= 0 &&
            $0.horizontalAccuracy <= 50 &&
            abs($0.timestamp.timeIntervalSinceNow) <= 5
        }
        let newPoints = goodLocations.map {
            RoutePoint(
                latitude: $0.coordinate.latitude,
                longitude: $0.coordinate.longitude,
                altitudeMeters: $0.altitude,
                recordedAt: $0.timestamp,
                horizontalAccuracyMeters: $0.horizontalAccuracy,
                verticalAccuracyMeters: $0.verticalAccuracy
            )
        }
        Task { @MainActor in
            guard self.isTracking else { return }
            self.points.append(contentsOf: newPoints)
        }
    }
}
