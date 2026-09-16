import Foundation
import SwiftData
import LiftCore

enum OutdoorActivityType: String, Codable, CaseIterable, Identifiable {
    case run, walk, hike

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .run:  return "Run"
        case .walk: return "Walk"
        case .hike: return "Hike"
        }
    }
}

/// One recorded GPS point. A plain `Codable` value, not a `@Model` — a run
/// can produce thousands of points, and SwiftData rows (with their own
/// relationship/fetch machinery) are the wrong shape for an ordered list
/// nothing ever queries individually. Stored as encoded `Data` on the
/// owning `OutdoorActivity` instead, the same way `NutritionFacts` is
/// stored as a plain Codable value inline on `SetEntry`'s neighbors rather
/// than as its own model.
struct RoutePoint: Codable, Equatable {
    var latitude: Double
    var longitude: Double
    var altitudeMeters: Double
    var recordedAt: Date
    var horizontalAccuracyMeters: Double
    var verticalAccuracyMeters: Double
}

/// A GPS-tracked Run or Hike. Deliberately not part of `WorkoutDay` —
/// see the design spec's "own section" decision. LIFT owns the route data
/// itself (`routePointsData`); `healthKitUUID` is set only once the
/// finished activity has been exported, the same idempotency pattern
/// `WorkoutDay.healthKitUUID` already uses for strength workouts.
@Model
final class OutdoorActivity {
    var id: UUID = UUID()

    private var activityTypeRaw: String = OutdoorActivityType.run.rawValue
    var activityType: OutdoorActivityType {
        get { OutdoorActivityType(rawValue: activityTypeRaw) ?? .run }
        set { activityTypeRaw = newValue.rawValue }
    }

    var startedAt: Date = Date.now
    var endedAt: Date?

    var distanceMeters: Double = 0
    var elevationGainMeters: Double = 0
    var activeCalories: Double?

    /// JSON-encoded `[RoutePoint]`. See `routePoints` below.
    var routePointsData: Data = Data()

    var healthKitUUID: UUID?

    init(activityType: OutdoorActivityType, startedAt: Date = .now) {
        self.id = UUID()
        self.activityTypeRaw = activityType.rawValue
        self.startedAt = startedAt
    }

    var routePoints: [RoutePoint] {
        get { (try? JSONDecoder().decode([RoutePoint].self, from: routePointsData)) ?? [] }
        set { routePointsData = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }

    var duration: TimeInterval? {
        guard let endedAt else { return nil }
        return endedAt.timeIntervalSince(startedAt)
    }

    /// Seconds per meter — the canonical form. Views convert to
    /// minutes-per-mile/km for display via `DistanceUnit`.
    var averagePaceSecondsPerMeter: Double? {
        guard let duration, distanceMeters > 0 else { return nil }
        return duration / distanceMeters
    }
}

extension OutdoorActivity: Identifiable {}

// MARK: - Calculations

enum OutdoorActivityMath {

    /// Sums point-to-point great-circle distance (`CLLocation`'s own
    /// `distance(from:)` is the natural fit once this runs against real
    /// `CLLocation` values in `LocationTracker` — this pure-math version
    /// takes plain coordinates so it stays unit-testable without CoreLocation
    /// device dependencies).
    static func totalDistanceMeters(_ points: [RoutePoint]) -> Double {
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
    static func elevationGainMeters(_ points: [RoutePoint], minimumDeltaMeters: Double = 3.0) -> Double {
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
