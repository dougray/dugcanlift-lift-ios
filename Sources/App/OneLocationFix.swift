import CoreLocation

/// One position, once, for the Maps section's "around here" offer. It uses the
/// permission the app already has: **it never asks.** Without When In Use (or
/// Always) it answers nil at once, and the offer is simply not shown, so
/// opening Settings can never raise a location prompt. The fix is a single
/// `requestLocation()`, not a recording: nothing is stored and nothing keeps
/// running.
@MainActor
final class OneLocationFix: NSObject, CLLocationManagerDelegate {

    /// Built on first use, not with this object: Settings holds one of these in
    /// view state, and a `CLLocationManager` should exist only once somebody
    /// actually asks for a fix.
    private lazy var manager = CLLocationManager()
    /// Tests give the status; the app reads the manager's own.
    private let statusProvider: (() -> CLAuthorizationStatus)?
    private var continuation: CheckedContinuation<(Double, Double)?, Never>?

    init(status: (() -> CLAuthorizationStatus)? = nil) {
        statusProvider = status
        super.init()
    }

    private var status: CLAuthorizationStatus { statusProvider?() ?? manager.authorizationStatus }

    /// The never-prompts rule as a pure decision: only a permission the person
    /// has already given may be read. Not determined, denied and restricted all
    /// answer nil without asking CoreLocation for anything.
    static func isAllowed(_ status: CLAuthorizationStatus) -> Bool {
        status == .authorizedWhenInUse || status == .authorizedAlways
    }

    /// Latitude and longitude, or nil: no permission, no fix, or a fix that
    /// could not be read.
    func current() async -> (Double, Double)? {
        guard Self.isAllowed(status), continuation == nil else { return nil }
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
