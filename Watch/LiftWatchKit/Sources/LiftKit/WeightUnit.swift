import Foundation

/// Mirrors the phone app's `WeightUnit`. Weight is stored canonically in
/// kilograms everywhere; the unit is a display concern only. Mixed-unit
/// history is unrecoverable once it happens, so nothing here writes pounds.
public enum WeightUnit: String, Codable, CaseIterable, Sendable {
    case pounds, kilograms

    private static let poundsPerKilogram = 2.2046226218

    public var abbreviation: String { self == .kilograms ? "kg" : "lb" }

    public func fromKilograms(_ kg: Double) -> Double {
        self == .kilograms ? kg : kg * Self.poundsPerKilogram
    }

    public func toKilograms(_ value: Double) -> Double {
        self == .kilograms ? value : value / Self.poundsPerKilogram
    }
}
