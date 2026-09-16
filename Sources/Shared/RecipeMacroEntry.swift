import Foundation
import LiftCore

/// What the recipe editor's macro fields add up to, and what they must not
/// throw away.
///
/// A value type with no view in it, for the reason Coach's `MacroFields` is
/// one: a rule living in a view's `@State` cannot be tested, and this one
/// decides whether numbers survive a save.
///
/// `NutritionFacts` carries eight values, and the editor now has a field for
/// every one: the five macros, and saturated fat, sugar and sodium under "More
/// nutrients". It used to show five and carry sugar and sodium forward unseen,
/// because rebuilding the facts from the visible fields alone had silently
/// dropped what `RecipeJSONLD` read off a page. With a field for each, the
/// field is the answer: the editor loads all eight, so an untouched save keeps
/// them, and a field the person clears is cleared.
enum RecipeMacroEntry {

    /// nil unless something was actually typed — an untouched form must not
    /// write zeros, which would later log as a zero-calorie meal.
    ///
    /// Everything after the first four stays nil when blank: fibre, saturated
    /// fat, sugar and sodium are optional on `NutritionFacts`, and a dish whose
    /// source never said how much sodium it has must not claim to have none.
    static func entered(calories: String,
                        protein: String,
                        carbs: String,
                        fat: String,
                        fiber: String,
                        saturatedFat: String,
                        sugar: String,
                        sodium: String) -> NutritionFacts? {

        let values = [calories, protein, carbs, fat, fiber, saturatedFat, sugar, sodium].map {
            Double($0.trimmingCharacters(in: .whitespaces))
        }
        guard values.contains(where: { $0 != nil }) else { return nil }

        return NutritionFacts(
            calories: values[0] ?? 0,
            proteinG: values[1] ?? 0,
            carbsG: values[2] ?? 0,
            fatG: values[3] ?? 0,
            fiberG: values[4],
            sugarG: values[6],
            sodiumMg: values[7],
            saturatedFatG: values[5]
        )
    }
}
