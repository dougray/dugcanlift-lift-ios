import Foundation
import LiftSync

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

/// How large and how small one logged portion may be, in one place.
///
/// Settled 2026-09-13 at 2000 g on both watches. Before that, watchOS
/// contradicted itself: `LibraryFoodAmountView` stopped at 1000 g while
/// `FoodAmountEntryView` allowed 2000 g, so the same 1.5 kg cook-up was
/// loggable or not depending on whether the food had arrived from the phone.
///
/// The ounce bound is **derived by conversion**, never given its own rounded
/// literal. A separate `70` was worth 1984.5 g, so switching units near the
/// cap silently dropped grams. This mirrors Wear's `MAX_GRAMS`, which has
/// always derived its ounce side the same way.
public enum AmountLimits {

    public static let maxGrams: Double = 2000

    /// Below this a 0 g / 0 kcal entry was loggable — meaningless, but it
    /// still spent a slot in the 200-entry cap and a row in an exported code.
    public static let minGrams: Double = 5

    public static func maximum(in unit: ServingUnit) -> Double { unit.fromGrams(maxGrams) }

    public static func minimum(in unit: ServingUnit) -> Double { unit.fromGrams(minGrams) }
}
