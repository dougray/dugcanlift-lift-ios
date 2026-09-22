import XCTest
@testable import LiftKit

final class FoodLogMealTests: XCTestCase {
    func testRawValuesMatchWireContract() {
        XCTAssertEqual(FoodLogMeal.breakfast.rawValue, "BREAKFAST")
        XCTAssertEqual(FoodLogMeal.lunch.rawValue, "LUNCH")
        XCTAssertEqual(FoodLogMeal.dinner.rawValue, "DINNER")
        XCTAssertEqual(FoodLogMeal.snack.rawValue, "SNACK")
    }

    func testForHourBoundaries() {
        XCTAssertEqual(FoodLogMeal.forHour(6), .breakfast)
        XCTAssertEqual(FoodLogMeal.forHour(12), .lunch)
        XCTAssertEqual(FoodLogMeal.forHour(18), .dinner)
        XCTAssertEqual(FoodLogMeal.forHour(23), .snack)
        XCTAssertEqual(FoodLogMeal.forHour(2), .snack)
    }
}
