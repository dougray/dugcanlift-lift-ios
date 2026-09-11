import Foundation

/// Mirrors the phone app's `ServingUnit`. A logged amount is always stored
/// canonically in grams (see `FoodLogPayload.amountGrams`); the unit is a
/// display/entry concern only, exactly matching how `WeightUnit` handles
/// kilograms.
public enum ServingUnit: String, Codable, CaseIterable, Sendable {
    case grams, ounces

    private static let gramsPerOunce = 28.3495231

    public var abbreviation: String { self == .grams ? "g" : "oz" }

    public func fromGrams(_ grams: Double) -> Double {
        self == .grams ? grams : grams / Self.gramsPerOunce
    }

    public func toGrams(_ value: Double) -> Double {
        self == .grams ? value : value * Self.gramsPerOunce
    }
}
