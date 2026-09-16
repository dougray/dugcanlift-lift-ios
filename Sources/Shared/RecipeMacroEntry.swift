import Foundation
import LiftCore

/// What the recipe editor's macro fields add up to, and what they must not
/// throw away.
///
/// A value type with no view in it, for the reason Coach's `MacroFields` is
/// one: a rule living in a view's `@State` cannot be tested, and this one
/// decides whether numbers survive a save.
///
/// `NutritionFacts` carries seven values. The editor shows five. The two it
/// does not show — sugar and sodium — have to be carried forward rather than
/// rebuilt, because `RecipeJSONLD` reads all three of fibre, sugar and sodium
/// off a page, and before this existed the editor returned a fresh
/// `NutritionFacts` built from the visible fields alone. Opening an imported
/// recipe and tapping Save silently dropped all three.
enum RecipeMacroEntry {

    /// nil unless something was actually typed — an untouched form must not
    /// write zeros, which would later log as a zero-calorie meal.
    ///
    /// - Parameter existing: the recipe's current facts, for the values that
    ///   have no field of their own.
    static func entered(calories: String,
                        protein: String,
                        carbs: String,
                        fat: String,
                        fiber: String,
                        merging existing: NutritionFacts?) -> NutritionFacts? {

        let values = [calories, protein, carbs, fat, fiber].map {
            Double($0.trimmingCharacters(in: .whitespaces))
        }
        guard values.contains(where: { $0 != nil }) else { return nil }

        var result = NutritionFacts(
            calories: values[0] ?? 0,
            proteinG: values[1] ?? 0,
            carbsG: values[2] ?? 0,
            fatG: values[3] ?? 0
        )
        // Fibre is optional on `NutritionFacts` where the first four are not,
        // so a blank field stays nil rather than becoming a measured zero: a
        // dish whose ingredients carry no fibre data must not claim to have
        // none.
        result.fiberG = values[4]
        result.sugarG = existing?.sugarG
        result.sodiumMg = existing?.sodiumMg
        return result
    }
}
