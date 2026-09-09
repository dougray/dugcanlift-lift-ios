import Foundation

/// Mirrors `WeightUnit`/`DistanceUnit` exactly. Amounts are stored
/// canonically in grams; this handles display conversion only, at the view
/// layer.
enum ServingUnit: String, Codable, CaseIterable {
    case grams, ounces

    private static let gramsPerOunce = 28.3495

    var abbreviation: String { self == .grams ? "g" : "oz" }

    func fromGrams(_ grams: Double) -> Double {
        self == .grams ? grams : grams / Self.gramsPerOunce
    }

    func toGrams(_ value: Double) -> Double {
        self == .grams ? value : value * Self.gramsPerOunce
    }
}
