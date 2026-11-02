import XCTest
import LiftCore
import LiftReference
@testable import Lift

/// `LoggableFood(record:)` is what food search logs for every library food, so
/// it must say exactly what the record says: the same `foodRefID`, and the same
/// nutrition at any amount, an unrecorded nutrient staying unrecorded.
final class LoggableFoodTests: XCTestCase {
    /// `FoodRecord` has no public initializer; decode one, as `RecipeEditingTests` does.
    private func record() -> FoodRecord {
        let json: [String: Any] = [
            "id": "usda:test-123",
            "name": "Oats, rolled",
            "brand": "Test Mills",
            "caloriesPer100g": 379,
            "proteinPer100g": 13.2,
            "carbsPer100g": 67.7,
            "fatPer100g": 6.5,
            "fiberPer100g": 10.1,
            "source": "usda",
        ]
        let data = try! JSONSerialization.data(withJSONObject: json)
        return try! JSONDecoder().decode(FoodRecord.self, from: data)
    }

    func testALibraryFoodKeepsTheRecordsIdentity() {
        let record = record()
        let food = LoggableFood(record: record)
        XCTAssertEqual(food.id, record.id)
        XCTAssertEqual(food.name, "Oats, rolled")
        XCTAssertEqual(food.brand, "Test Mills")
        XCTAssertNil(food.rememberedCode)
    }

    func testItsNutritionIsTheRecordsAtHundredGramsAndAtAnyAmount() {
        let record = record()
        let food = LoggableFood(record: record)
        XCTAssertEqual(food.per100g, record.nutrition(grams: 100))
        XCTAssertEqual(food.nutrition(grams: 30), record.nutrition(grams: 30))
    }

    func testAnUnrecordedNutrientStaysNilRatherThanBecomingZero() {
        let food = LoggableFood(record: record())
        let thirty = food.nutrition(grams: 30)
        XCTAssertNil(thirty.sugarG)
        XCTAssertNil(thirty.sodiumMg)
        XCTAssertNil(thirty.saturatedFatG)
        XCTAssertNotNil(thirty.fiberG)
    }
}
