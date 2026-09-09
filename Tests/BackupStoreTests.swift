import XCTest
import SwiftData
@testable import Lift

/// `amountGrams` travels through the backup file's common `food[]` shape,
/// same as `servings`/`calories` — it's a genuinely cross-platform field
/// (LIFT Android has it too, at the top level of its own export, with no
/// common/extras split at all), unlike `servingGrams` which stays iOS-only
/// under `ext.ios`. A round trip that dropped it would silently revert a
/// gram-logged entry back to legacy quantity/servingUnit display on restore.
final class BackupStoreTests: XCTestCase {

    private func makeContext() -> ModelContext {
        let container = LiftStore.makeContainer(inMemory: true)
        return ModelContext(container)
    }

    func testAmountGramsSurvivesBackupAndRestore() throws {
        let sourceContext = makeContext()
        let entry = FoodEntry(
            foodRefID: "usda:174608",
            name: "Chicken breast",
            quantity: 150,
            servingUnit: "g",
            amountGrams: 150,
            nutrition: NutritionFacts(calories: 248, proteinG: 46, carbsG: 0, fatG: 5),
            mealType: .lunch
        )
        sourceContext.insert(entry)
        try sourceContext.save()

        let data = try BackupStore.build(context: sourceContext)

        let destinationContext = makeContext()
        let result = BackupStore.restore(context: destinationContext, from: data)

        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.added, 1)

        let restored = try destinationContext.fetch(FetchDescriptor<FoodEntry>())
        XCTAssertEqual(restored.count, 1)
        XCTAssertEqual(restored.first?.amountGrams, 150, "amountGrams must round-trip through ext.ios.food")
        XCTAssertEqual(restored.first?.name, "Chicken breast")
    }

    func testEntriesWithoutAmountGramsRestoreAsNil() throws {
        let sourceContext = makeContext()
        let entry = FoodEntry(
            foodRefID: "off:3017620422003",
            name: "Chocolate bar",
            quantity: 1,
            servingUnit: "bar",
            nutrition: NutritionFacts(calories: 200, proteinG: 3, carbsG: 22, fatG: 11),
            mealType: .snack
        )
        sourceContext.insert(entry)
        try sourceContext.save()

        let data = try BackupStore.build(context: sourceContext)

        let destinationContext = makeContext()
        _ = BackupStore.restore(context: destinationContext, from: data)

        let restored = try destinationContext.fetch(FetchDescriptor<FoodEntry>())
        XCTAssertEqual(restored.count, 1)
        XCTAssertNil(restored.first?.amountGrams, "no amountGrams on the source entry means none after restore either")
    }
}
