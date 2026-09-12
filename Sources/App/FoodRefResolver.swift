import Foundation
import SwiftData
import LiftCore
import LiftReference

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
/// only (see `dugcanlift-kit/Sources/LiftReference/ReferenceDatabase.swift`
/// and this project's `CLAUDE.md`, "Shared code lives in LiftKit"). `Shared`
/// is compiled into the widget extension too, which links neither GRDB nor
/// `LiftReference`, so putting this file there would break `LiftWidgets`
/// with an undefined `ReferenceDatabase` symbol.
enum FoodRefResolver {
    /// `@MainActor`, not `nonisolated` (the SE-0338 default for a free
    /// static function): the `recipe:` branch below calls
    /// `context.fetch(descriptor)` against a `ModelContext` that is always
    /// `LiftStore.shared.mainContext`, a `@MainActor`-isolated context. Its
    /// only production caller, `WatchSyncReceiver.handleFoodLogged`, is
    /// itself `@MainActor` — but per SE-0338 an `await` on a `nonisolated
    /// async` function does NOT inherit the caller's actor, so without this
    /// annotation the function body (and its `context.fetch`) would run on
    /// the cooperative thread pool instead, off the main actor. Same defect
    /// class as the `pushRecentFoodsSnapshot()` fix elsewhere in this
    /// branch.
    @MainActor
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
