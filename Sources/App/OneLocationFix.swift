import CoreLocation

/// One position, once, for the Maps section's "around here" offer. It uses the
/// permission the app already has: **it never asks.** Without When In Use (or
/// Always) it answers nil at once, and the offer is simply not shown, so
/// opening Settings can never raise a location prompt. The fix is a single
/// `requestLocation()`, not a recording: nothing is stored and nothing keeps
/// running.
@MainActor
final class OneLocationFix: NSObject, CLLocationManagerDelegate {

    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<(Double, Double)?, Never>?

    /// True when the person has already allowed location while the app is open.
    static func isAllowed(_ status: CLAuthorizationStatus) -> Bool {
        status == .authorizedWhenInUse || status == .authorizedAlways
    }

    /// Latitude and longitude, or nil: no permission, no fix, or a fix that
    /// could not be read.
    func current() async -> (Double, Double)? {
        guard Self.isAllowed(manager.authorizationStatus), continuation == nil else { return nil }
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            manager.requestLocation()
        }
    }

    private func finish(_ value: (Double, Double)?) {
        continuation?.resume(returning: value)
        continuation = nil
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let last = locations.last
        Task { @MainActor in
            self.finish(last.map { ($0.coordinate.latitude, $0.coordinate.longitude) })
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.finish(nil) }
    }
}
