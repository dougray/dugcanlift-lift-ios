import Foundation
import LiftCore
import LiftReference

/// Anything food search can log at an amount: a library record or a food the
/// person remembered against a barcode. One amount step serves both.
struct LoggableFood: Identifiable, Equatable {
    static let rememberedLine = "A food you entered."

    /// The `foodRefID` an entry logged from this food carries.
    let id: String
    let name: String
    let brand: String?
    let per100g: NutritionFacts
    /// Set only for a remembered food: what Edit and Forget act on.
    let rememberedCode: String?

    init(record: FoodRecord) {
        id = record.id
        name = record.name
        brand = record.brand
        per100g = record.nutrition(grams: 100)
        rememberedCode = nil
    }

    init(remembered food: RememberedFood) {
        id = "barcode:" + food.code
        name = food.name
        brand = food.brand
        per100g = food.per100g
        rememberedCode = food.code
    }

    func nutrition(grams: Double) -> NutritionFacts { per100g.scaled(by: grams / 100) }
}
