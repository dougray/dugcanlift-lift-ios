import XCTest
import SwiftData
import LiftCore
import LiftReference
@testable import Lift

/// `FoodRefResolver` is the one genuinely new piece of shared logic in the
/// watch-sync feature: neither `FoodSearchView` (already holds a
/// `FoodRecord`) nor recipe logging (already holds a `Recipe`) has ever
/// needed to resolve a bare `foodRefID` string into a name and gram-scaled
/// nutrition. A watch-originated quick-log request only ever hands over the
/// ID.
final class FoodRefResolverTests: XCTestCase {

    private func makeContext() -> ModelContext {
        let container = LiftStore.makeContainer(inMemory: true)
        return ModelContext(container)
    }

    // MARK: - Reference-database food

    /// "usda:174608" — Chicken breast, roll, oven-roasted — is a real row in
    /// the bundled `food.db` (per 100g: 134.0 kcal, 14.59g protein, 1.79g
    /// carbs, 7.65g fat, 0.0g fiber, 0.43g sugar, 883.0mg sodium), the same
    /// fixture ID already used as a real-food example in
    /// `RecentFoodsQueryTests`.
    func testResolvesReferenceDatabaseFoodScaledByGrams() async throws {
        let context = makeContext()

        let result = await FoodRefResolver.nutrition(
            for: "usda:174608", grams: 150, context: context
        )

        let resolved = try XCTUnwrap(result)
        XCTAssertEqual(resolved.name, "Chicken breast, roll, oven-roasted")
        XCTAssertEqual(resolved.nutrition.calories, 201.0, accuracy: 0.01)
        XCTAssertEqual(resolved.nutrition.proteinG, 21.885, accuracy: 0.01)
        XCTAssertEqual(resolved.nutrition.carbsG, 2.685, accuracy: 0.01)
        XCTAssertEqual(resolved.nutrition.fatG, 11.475, accuracy: 0.01)
        XCTAssertEqual(resolved.nutrition.fiberG ?? -1, 0.0, accuracy: 0.01)
        XCTAssertEqual(resolved.nutrition.sugarG ?? -1, 0.645, accuracy: 0.01)
        XCTAssertEqual(resolved.nutrition.sodiumMg ?? -1, 1324.5, accuracy: 0.01)
    }

    // MARK: - Recipe

    func testResolvesRecipeScaledByGrams() async throws {
        let context = makeContext()
        let recipe = Recipe(
            name: "Chicken Stir Fry",
            nutritionPerServing: NutritionFacts(
                calories: 400, proteinG: 30, carbsG: 20, fatG: 15,
                fiberG: 4, sugarG: 6, sodiumMg: 600
            )
        )
        recipe.totalWeightGrams = 800 // 4 servings x 200g/serving
        context.insert(recipe)
        try context.save()

        // nutritionPerGram = totalNutrition (400*1 serving = 400 kcal etc,
        // servings defaults to 1) / totalWeightGrams(800) — per-gram basis.
        // totalNutrition = nutritionPerServing.scaled(by: servings == 1) == nutritionPerServing.
        let result = await FoodRefResolver.nutrition(
            for: recipe.foodRefID, grams: 200, context: context
        )

        let resolved = try XCTUnwrap(result)
        XCTAssertEqual(resolved.name, "Chicken Stir Fry")
        // perGram = 400/800 = 0.5 kcal/g; scaled by 200g = 100 kcal.
        XCTAssertEqual(resolved.nutrition.calories, 100.0, accuracy: 0.01)
        XCTAssertEqual(resolved.nutrition.proteinG, 7.5, accuracy: 0.01)
        XCTAssertEqual(resolved.nutrition.carbsG, 5.0, accuracy: 0.01)
        XCTAssertEqual(resolved.nutrition.fatG, 3.75, accuracy: 0.01)
    }

    func testRecipeMissingTotalWeightGramsReturnsNil() async throws {
        let context = makeContext()
        let recipe = Recipe(
            name: "No Weight Recipe",
            nutritionPerServing: NutritionFacts(calories: 300, proteinG: 10, carbsG: 30, fatG: 10)
        )
        // totalWeightGrams left nil -> nutritionPerGram is nil -> unresolvable.
        context.insert(recipe)
        try context.save()

        let result = await FoodRefResolver.nutrition(
            for: recipe.foodRefID, grams: 100, context: context
        )

        XCTAssertNil(result)
    }

    // MARK: - Unresolvable IDs

    func testUnknownRecipeUUIDReturnsNilWithoutCrashing() async throws {
        let context = makeContext()

        let result = await FoodRefResolver.nutrition(
            for: "recipe:\(UUID().uuidString)", grams: 100, context: context
        )

        XCTAssertNil(result)
    }

    func testNonsenseRefIDReturnsNilWithoutCrashing() async throws {
        let context = makeContext()

        let result = await FoodRefResolver.nutrition(
            for: "not-a-real-ref-id", grams: 100, context: context
        )

        XCTAssertNil(result)
    }

    func testMalformedRecipeUUIDReturnsNilWithoutCrashing() async throws {
        let context = makeContext()

        let result = await FoodRefResolver.nutrition(
            for: "recipe:not-a-uuid", grams: 100, context: context
        )

        XCTAssertNil(result)
    }
}
