import Foundation

/// Ported from `lift-ios`'s `Sources/Shared/OutdoorActivityModels.swift`.
/// Same formula, same constants — this must compute identical numbers to the
/// iOS phone app and the Android app from the same input data.
public enum OutdoorActivityType: String, Codable, CaseIterable, Identifiable, Sendable {
    case run, hike

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .run:  return "Run"
        case .hike: return "Hike"
        }
    }
}

/// One recorded GPS point. A plain `Codable` value — a run can produce
/// thousands of points, and store machinery (relationships/individual
/// fetches) is the wrong shape for an ordered list nothing ever queries
/// individually.
public struct RoutePoint: Codable, Equatable, Sendable {
    public var latitude: Double
    public var longitude: Double
    public var altitudeMeters: Double
    public var recordedAt: Date
    public var horizontalAccuracyMeters: Double
    public var verticalAccuracyMeters: Double

    public init(
        latitude: Double,
        longitude: Double,
        altitudeMeters: Double,
        recordedAt: Date,
        horizontalAccuracyMeters: Double,
        verticalAccuracyMeters: Double
    ) {
        self.latitude = latitude
        self.longitude = longitude
        self.altitudeMeters = altitudeMeters
        self.recordedAt = recordedAt
        self.horizontalAccuracyMeters = horizontalAccuracyMeters
        self.verticalAccuracyMeters = verticalAccuracyMeters
    }
}

// MARK: - Calculations

public enum OutdoorActivityMath {

    /// Sums point-to-point great-circle distance (`CLLocation`'s own
    /// `distance(from:)` is the natural fit once this runs against real
    /// `CLLocation` values on-device — this pure-math version takes plain
    /// coordinates so it stays unit-testable without CoreLocation device
    /// dependencies).
    public static func totalDistanceMeters(_ points: [RoutePoint]) -> Double {
        guard points.count > 1 else { return 0 }
        var total = 0.0
        for i in 1..<points.count {
            total += haversineMeters(
                lat1: points[i - 1].latitude, lon1: points[i - 1].longitude,
                lat2: points[i].latitude, lon2: points[i].longitude
            )
        }
        return total
    }

    /// Noise-filtered elevation gain: GPS altitude readings jitter by several
    /// meters even standing still, so a naive sum of every positive delta
    /// wildly overcounts. Only deltas past `minimumDeltaMeters` between a
    /// point and the last point that cleared the threshold count as real
    /// gain — this is the standard technique (a simple hysteresis filter)
    /// used by GPS fitness trackers for exactly this noise problem.
    public static func elevationGainMeters(_ points: [RoutePoint], minimumDeltaMeters: Double = 3.0) -> Double {
        guard points.count > 1 else { return 0 }
        var gain = 0.0
        var reference = points[0].altitudeMeters
        for point in points.dropFirst() {
            let delta = point.altitudeMeters - reference
            if delta >= minimumDeltaMeters {
                gain += delta
                reference = point.altitudeMeters
            } else if delta <= -minimumDeltaMeters {
                reference = point.altitudeMeters
            }
        }
        return gain
    }

    private static let earthRadiusMeters = 6_371_000.0

    private static func haversineMeters(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double {
        let φ1 = lat1 * .pi / 180
        let φ2 = lat2 * .pi / 180
        let Δφ = (lat2 - lat1) * .pi / 180
        let Δλ = (lon2 - lon1) * .pi / 180
        let a = sin(Δφ / 2) * sin(Δφ / 2) + cos(φ1) * cos(φ2) * sin(Δλ / 2) * sin(Δλ / 2)
        let c = 2 * atan2(a.squareRoot(), (1 - a).squareRoot())
        return earthRadiusMeters * c
    }
}
