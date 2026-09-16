import Foundation
import LiftCore

/// Saturated fat, sugar and sodium: how LIFT names, rounds and totals them for
/// the screen.
///
/// **Tracked, never targeted.** There is no goal for any of the three, so
/// nothing here draws a bar or says "over". A food shows them only when its
/// source recorded them, and a day's total covers only the foods that did — a
/// partial total is a floor, not a day, so it says how many foods it covers.
///
/// **Nil is "the source did not say", never zero.** A banana from the food
/// database has sugar; a food restored from a file written before these
/// existed may not.
///
/// Rounding is `ShareNutrients`' — grams to one decimal, sodium to whole
/// milligrams, day totals summed unrounded — so what the person reads here is
/// exactly what a coach reads from the same day in a share link. A value type
/// with no view in it, so the rules are tested rather than eyeballed.
enum NutrientDetailsDisplay {

    enum Nutrient: CaseIterable, Identifiable {
        case saturatedFat, sugar, sodium

        var id: Self { self }

        var label: String {
            switch self {
            case .saturatedFat: "Saturated fat"
            case .sugar:        "Sugar"
            case .sodium:       "Sodium"
            }
        }

        /// For the one-line summary under a logged food, beside "P 8 - F 2".
        var shortLabel: String {
            switch self {
            case .saturatedFat: "Sat fat"
            case .sugar:        "Sugar"
            case .sodium:       "Sodium"
            }
        }

        var unit: String { self == .sodium ? "mg" : "g" }

        func value(in facts: NutritionFacts) -> Double? {
            let raw: Double? = switch self {
            case .saturatedFat: facts.saturatedFatG
            case .sugar:        facts.sugarG
            case .sodium:       facts.sodiumMg
            }
            return raw.flatMap { $0.isFinite ? $0 : nil }
        }

        func set(_ value: Double?, in facts: inout NutritionFacts) {
            switch self {
            case .saturatedFat: facts.saturatedFatG = value
            case .sugar:        facts.sugarG = value
            case .sodium:       facts.sodiumMg = value
            }
        }

        /// "3.1 g", "540 mg", "1,840 mg".
        func formatted(_ value: Double, locale: Locale = .current) -> String {
            let rounded = self == .sodium
                ? ShareNutrients.roundMilligrams(value)
                : ShareNutrients.roundGrams(value)
            let number = rounded.formatted(
                .number.precision(.fractionLength(0...(self == .sodium ? 0 : 1))).locale(locale))
            return "\(number) \(unit)"
        }
    }

    /// "Sat fat 3.1 g - Sugar 14.7 g - Sodium 1 mg", for a food whose source
    /// recorded any of the three; nil when it recorded none.
    static func entryLine(_ facts: NutritionFacts, locale: Locale = .current) -> String? {
        let parts = Nutrient.allCases.compactMap { nutrient in
            nutrient.value(in: facts).map { "\(nutrient.shortLabel) \(nutrient.formatted($0, locale: locale))" }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " - ")
    }

    /// One line of a day's totals.
    struct Total: Equatable, Identifiable {
        let nutrient: Nutrient
        /// "1,840 mg".
        let value: String
        /// "from 3 of 5 foods" when some foods did not record it; nil when all did.
        let coverage: String?

        var id: Nutrient { nutrient }
    }

    /// Totals for a day's foods — pass every food logged, including ones that
    /// recorded none of the three, so the coverage counts are honest. A
    /// nutrient no food recorded is left out; no food recording any gives an
    /// empty array, and the screen shows nothing.
    ///
    /// `FoodEntry.nutrition` is already scaled to what was eaten, so each food
    /// counts once at servings 1 — the same call `CoachShare` makes for `fx`.
    static func dayTotals(_ foods: [NutritionFacts], locale: Locale = .current) -> [Total] {
        guard let totals = ShareNutrients.dayTotals(
            foods.map { (servings: 1, details: WireNutrientDetails($0)) }) else { return [] }

        let rows: [(Nutrient, Double?, Int)] = [
            (.saturatedFat, totals.saturatedFatG, totals.withSaturatedFat),
            (.sugar, totals.sugarG, totals.withSugar),
            (.sodium, totals.sodiumMg, totals.withSodium),
        ]
        return rows.compactMap { nutrient, value, covered in
            guard let value, covered > 0 else { return nil }
            let coverage = covered < totals.foods
                ? "from \(covered) of \(totals.foods) foods"
                : nil
            return Total(nutrient: nutrient, value: nutrient.formatted(value, locale: locale), coverage: coverage)
        }
    }
}
