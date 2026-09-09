import Foundation
import SwiftData

/// Resolves an arbitrary `foodRefID` (whatever its source — a reference-
/// database food or a recipe) into a name and gram-scaled nutrition.
/// Neither existing logging path needs this: `FoodSearchView` already
/// holds a `FoodRecord` from search, `PlannedMeal.toFoodEntry()` already
/// holds a `Recipe`. A watch-originated request only ever hands over the
/// bare ID string, so this is the one place that has to go find the
/// thing `foodRefID` actually points at.
///
/// Lives in `Sources/App`, not `Sources/Shared`, even though everything
/// else touched by the watch-sync feature sits in `Shared`: this type
/// depends on `ReferenceDatabase`, which is GRDB-backed and app-target
/// only (see `Sources/Reference/ReferenceDatabase.swift` and the
/// `Sources/Reference` comment in the project's `CLAUDE.md`). `Shared` is
/// compiled into the widget extension too, which links neither GRDB nor
/// `Sources/Reference`, so putting this file there would break
/// `LiftWidgets` with an undefined `ReferenceDatabase` symbol.
enum FoodRefResolver {
    static func nutrition(
        for foodRefID: String,
        grams: Double,
        context: ModelContext
    ) async -> (name: String, nutrition: NutritionFacts)? {
        if foodRefID.hasPrefix("recipe:") {
            guard let idString = foodRefID.split(separator: ":", maxSplits: 1).last,
                  let recipeID = UUID(uuidString: String(idString))
            else { return nil }
            let descriptor = FetchDescriptor<Recipe>(
                predicate: #Predicate { $0.id == recipeID }
            )
            guard let recipe = try? context.fetch(descriptor).first,
                  let perGram = recipe.nutritionPerGram
            else { return nil }
            return (recipe.name, perGram.scaled(by: grams))
        }

        guard let record = try? await ReferenceDatabase.shared.food(id: foodRefID)
        else { return nil }
        return (record.name, record.nutrition(grams: grams))
    }
}
