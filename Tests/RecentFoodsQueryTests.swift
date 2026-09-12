import XCTest
import SwiftData
import LiftCore
@testable import Lift

/// `RecentFoodsQuery.recent` is the extraction of `FoodView`'s original
/// `recent` computed property: dedup by display name (brand + name), newest
/// first, capped at `limit`, operating on a fetched array instead of a
/// `@Query` property so it also works from non-View call sites (the watch
/// quick-log snapshot in particular).
final class RecentFoodsQueryTests: XCTestCase {

    private func makeContext() -> ModelContext {
        let container = LiftStore.makeContainer(inMemory: true)
        return ModelContext(container)
    }

    private func makeEntry(
        foodRefID: String, name: String, brand: String? = nil,
        loggedAt: Date, mealType: MealType = .snack
    ) -> FoodEntry {
        FoodEntry(
            foodRefID: foodRefID,
            name: name,
            brand: brand,
            quantity: 1,
            servingUnit: "serving",
            nutrition: NutritionFacts(calories: 100, proteinG: 5, carbsG: 10, fatG: 2),
            mealType: mealType,
            loggedAt: loggedAt
        )
    }

    func testDedupesByDisplayNameKeepingNewest() throws {
        let context = makeContext()
        let older = makeEntry(
            foodRefID: "usda:1", name: "Oats", brand: "Quaker",
            loggedAt: Date(timeIntervalSince1970: 1000)
        )
        let newer = makeEntry(
            foodRefID: "usda:2", name: "Oats", brand: "Quaker",
            loggedAt: Date(timeIntervalSince1970: 2000)
        )
        context.insert(older)
        context.insert(newer)
        try context.save()

        let result = RecentFoodsQuery.recent(context: context, limit: 10)

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.foodRefID, "usda:2", "the newest of the duplicate-name entries should survive")
    }

    func testCapsAtLimit() throws {
        let context = makeContext()
        for i in 0..<15 {
            let entry = makeEntry(
                foodRefID: "usda:\(i)", name: "Food \(i)",
                loggedAt: Date(timeIntervalSince1970: Double(i))
            )
            context.insert(entry)
        }
        try context.save()

        let result = RecentFoodsQuery.recent(context: context, limit: 10)

        XCTAssertEqual(result.count, 10)
    }

    func testNewestFirstOrdering() throws {
        let context = makeContext()
        let first = makeEntry(foodRefID: "usda:1", name: "Apple", loggedAt: Date(timeIntervalSince1970: 100))
        let second = makeEntry(foodRefID: "usda:2", name: "Banana", loggedAt: Date(timeIntervalSince1970: 300))
        let third = makeEntry(foodRefID: "usda:3", name: "Carrot", loggedAt: Date(timeIntervalSince1970: 200))
        context.insert(first)
        context.insert(second)
        context.insert(third)
        try context.save()

        let result = RecentFoodsQuery.recent(context: context, limit: 10)

        XCTAssertEqual(result.map(\.foodRefID), ["usda:2", "usda:3", "usda:1"])
    }

    func testRecipeDerivedAndSingleFoodEntriesMixTogether() throws {
        let context = makeContext()
        let recipeEntry = makeEntry(
            foodRefID: "recipe:abc123", name: "Chicken Stir Fry",
            loggedAt: Date(timeIntervalSince1970: 500)
        )
        let singleFoodEntry = makeEntry(
            foodRefID: "usda:174608", name: "Oats", brand: nil,
            loggedAt: Date(timeIntervalSince1970: 400)
        )
        context.insert(recipeEntry)
        context.insert(singleFoodEntry)
        try context.save()

        let result = RecentFoodsQuery.recent(context: context, limit: 10)

        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result.map(\.foodRefID), ["recipe:abc123", "usda:174608"])
        XCTAssertTrue(result[0].foodRefID.hasPrefix("recipe:"))
        XCTAssertFalse(result[1].foodRefID.hasPrefix("recipe:"))
    }

    func testEmptyDisplayNameIsExcluded() throws {
        let context = makeContext()
        let blank = makeEntry(foodRefID: "usda:1", name: "  ", loggedAt: Date(timeIntervalSince1970: 100))
        let valid = makeEntry(foodRefID: "usda:2", name: "Rice", loggedAt: Date(timeIntervalSince1970: 200))
        context.insert(blank)
        context.insert(valid)
        try context.save()

        let result = RecentFoodsQuery.recent(context: context, limit: 10)

        XCTAssertEqual(result.map(\.foodRefID), ["usda:2"])
    }
}
