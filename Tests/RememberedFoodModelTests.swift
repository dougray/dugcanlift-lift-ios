import XCTest
import SwiftData
import LiftCore
@testable import Lift

final class RememberedFoodModelTests: XCTestCase {
    private var storeURL: URL!

    override func setUp() {
        storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("v9to10-\(UUID().uuidString).store")
    }
    override func tearDown() {
        for suffix in ["", "-shm", "-wal"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: storeURL.path + suffix))
        }
    }

    func testAV9StoreOpensAsV10WithItsFoodIntact() throws {
        do {
            let v9 = try ModelContainer(for: Schema(versionedSchema: LiftSchemaV9.self),
                                        configurations: [ModelConfiguration(url: storeURL)])
            let context = ModelContext(v9)
            context.insert(FoodEntry(foodRefID: "usda:174608", name: "Oats", brand: nil,
                                     quantity: 40, servingUnit: "g", amountGrams: 40,
                                     nutrition: NutritionFacts(calories: 150, proteinG: 5, carbsG: 27, fatG: 3),
                                     mealType: .breakfast))
            try context.save()
        }
        let v10 = try ModelContainer(for: Schema(versionedSchema: LiftSchemaV10.self),
                                     migrationPlan: LiftMigrationPlan.self,
                                     configurations: [ModelConfiguration(url: storeURL)])
        let context = ModelContext(v10)
        let food = try context.fetch(FetchDescriptor<FoodEntry>())
        XCTAssertEqual(food.map(\.name), ["Oats"])
        XCTAssertEqual(food.first?.nutrition.calories, 150)
        XCTAssertEqual(try context.fetch(FetchDescriptor<RememberedFood>()).count, 0)

        context.insert(RememberedFood(code: "36000291452", name: "Corn flakes",
                                      per100g: NutritionFacts(calories: 357, proteinG: 7, carbsG: 84, fatG: 0.4)))
        try context.save()
        XCTAssertEqual(try context.fetch(FetchDescriptor<RememberedFood>()).first?.name, "Corn flakes")
    }

    func testABlankOptionalNutrientStaysNilThroughTheStore() throws {
        let context = ModelContext(LiftStore.makeContainer(inMemory: true))
        context.insert(RememberedFood(code: "4006381333931", name: "Pencil-shaped snack",
                                      per100g: NutritionFacts(calories: 400, proteinG: 10, carbsG: 60, fatG: 12)))
        try context.save()
        let back = try XCTUnwrap(context.fetch(FetchDescriptor<RememberedFood>()).first)
        XCTAssertNil(back.per100g.fiberG)
        XCTAssertNil(back.per100g.sodiumMg)
    }
}
