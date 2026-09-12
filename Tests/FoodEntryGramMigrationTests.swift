import XCTest
import SwiftData
import LiftCore
@testable import Lift

/// `FoodEntryGramMigration` is best-effort by design: a row with a known
/// `servingGrams` gets an exact `amountGrams` computed from it, and a row
/// without one is left completely untouched. Both branches — and the
/// idempotency that makes it safe to call on every launch — are covered here.
final class FoodEntryGramMigrationTests: XCTestCase {

    private func makeContext() -> ModelContext {
        let container = LiftStore.makeContainer(inMemory: true)
        return ModelContext(container)
    }

    func testBackfillsAmountGramsFromServingGramsAndQuantity() throws {
        let context = makeContext()
        let entry = FoodEntry(
            foodRefID: "usda:174608",
            name: "Oats",
            quantity: 2,
            servingUnit: "serving",
            servingGrams: 40,
            nutrition: NutritionFacts(calories: 300, proteinG: 10, carbsG: 54, fatG: 5),
            mealType: .breakfast
        )
        context.insert(entry)
        try context.save()

        FoodEntryGramMigration.run(context: context)

        XCTAssertEqual(entry.amountGrams, 80, "2 servings of 40g should backfill to 80g")
    }

    func testRowsWithoutServingGramsAreLeftUntouched() throws {
        let context = makeContext()
        let entry = FoodEntry(
            foodRefID: "off:3017620422003",
            name: "Chocolate bar",
            quantity: 1,
            servingUnit: "bar",
            servingGrams: nil,
            nutrition: NutritionFacts(calories: 200, proteinG: 3, carbsG: 22, fatG: 11),
            mealType: .snack
        )
        context.insert(entry)
        try context.save()

        FoodEntryGramMigration.run(context: context)

        XCTAssertNil(entry.amountGrams, "no servingGrams means no basis for a gram equivalent")
        XCTAssertEqual(entry.quantity, 1, "nothing else about the row should change")
        XCTAssertEqual(entry.servingUnit, "bar")
        XCTAssertNil(entry.servingGrams)
    }

    func testRunningTwiceIsANoOp() throws {
        let context = makeContext()
        let entry = FoodEntry(
            foodRefID: "usda:174608",
            name: "Oats",
            quantity: 3,
            servingUnit: "serving",
            servingGrams: 40,
            nutrition: NutritionFacts(calories: 300, proteinG: 10, carbsG: 54, fatG: 5),
            mealType: .breakfast
        )
        context.insert(entry)
        try context.save()

        FoodEntryGramMigration.run(context: context)
        XCTAssertEqual(entry.amountGrams, 120)

        // A second run must not touch an already-migrated row (the predicate
        // excludes it), so a value change here would mean the idempotency
        // guarantee is broken.
        entry.amountGrams = 999
        FoodEntryGramMigration.run(context: context)
        XCTAssertEqual(entry.amountGrams, 999, "already-migrated rows must be skipped on re-run")
    }
}
