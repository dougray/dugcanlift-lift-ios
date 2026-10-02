import Foundation

/// Ported from `lift-ios`'s `Sources/Shared/DistanceUnit.swift`. Mirrors
/// `WeightUnit` exactly: distance is stored canonically in meters everywhere;
/// this handles display conversion only, at the view layer.
public enum DistanceUnit: String, Codable, CaseIterable, Sendable {
    case miles, kilometers

    private static let metersPerMile = 1609.344

    public var abbreviation: String { self == .kilometers ? "km" : "mi" }

    public func fromMeters(_ meters: Double) -> Double {
        self == .kilometers ? meters / 1000 : meters / Self.metersPerMile
    }

    public func toMeters(_ value: Double) -> Double {
        self == .kilometers ? value * 1000 : value * Self.metersPerMile
    }
}
