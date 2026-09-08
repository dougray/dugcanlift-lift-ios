import Foundation

/// Mirrors `WeightUnit` exactly. Distance is stored canonically in meters;
/// this handles display conversion only, at the view layer.
enum DistanceUnit: String, Codable, CaseIterable {
    case miles, kilometers

    private static let metersPerMile = 1609.344

    var abbreviation: String { self == .kilometers ? "km" : "mi" }

    func fromMeters(_ meters: Double) -> Double {
        self == .kilometers ? meters / 1000 : meters / Self.metersPerMile
    }

    func toMeters(_ value: Double) -> Double {
        self == .kilometers ? value * 1000 : value * Self.metersPerMile
    }
}
