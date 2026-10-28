import XCTest
@testable import Lift

final class RoadFoodMealTests: XCTestCase {
    private let sandwich = RoadFoodItem(id: "x-sandwich", name: "Sandwich", kcal: 420.4, proteinG: 31.6, fatG: 12, carbsG: 40)
    private let milk = RoadFoodItem(id: "x-milk", name: "1% Milk", kcal: 100, proteinG: 8, fatG: 2.5, carbsG: 12)
    private let unlisted = RoadFoodItem(id: "x-secret", name: "Secret menu", kcal: 300, proteinG: nil, fatG: 10, carbsG: 30)

    private var menu: [RoadFoodItem] { [sandwich, milk, unlisted] }

    func testItemsAddUpAsTheyWouldBeLogged() {
        var meal = RoadFoodMeal()
        meal.add(sandwich)
        meal.add(milk)
        meal.add(milk)
        XCTAssertEqual(meal.itemCount, 3)
        XCTAssertEqual(meal.count(of: milk.id), 2)
        // Rounded per item, as each entry is logged: 420 + 100 + 100.
        XCTAssertEqual(meal.total(from: menu), .init(kcal: 620, proteinG: 48))
        XCTAssertEqual(meal.items(from: menu).map(\.id), [sandwich.id, milk.id, milk.id])
    }

    /// An item that can't be logged can't be in a total either: a sum missing
    /// one item's protein would be a smaller number passed off as the whole.
    func testAnItemThatCannotBeLoggedCannotBeAdded() {
        var meal = RoadFoodMeal()
        meal.add(unlisted)
        XCTAssertTrue(meal.isEmpty)
    }

    func testRemovingTakesOneAndThenTheLine() {
        var meal = RoadFoodMeal()
        meal.add(milk)
        meal.add(milk)
        meal.remove(milk)
        XCTAssertEqual(meal.count(of: milk.id), 1)
        meal.remove(milk)
        XCTAssertTrue(meal.isEmpty)
        meal.remove(milk)
        XCTAssertTrue(meal.isEmpty)
    }

    func testTheLineSaysWhatIsLeft() {
        var meal = RoadFoodMeal()
        meal.add(sandwich)
        meal.add(milk)
        XCTAssertEqual(meal.line(from: menu, remaining: RemainingMacros(calories: 900.7, proteinG: 60)),
                       "2 items · 520 kcal · 40 g protein · fits, 380 kcal to spare")
        XCTAssertEqual(meal.line(from: menu, remaining: RemainingMacros(calories: 400, proteinG: 60)),
                       "2 items · 520 kcal · 40 g protein · 120 kcal over what is left")
        XCTAssertEqual(meal.line(from: menu, remaining: RemainingMacros(calories: 520, proteinG: 60)),
                       "2 items · 520 kcal · 40 g protein · uses exactly what is left")
        XCTAssertEqual(meal.line(from: menu, remaining: nil), "2 items · 520 kcal · 40 g protein")
    }

    /// A menu that has lost an item since it was added logs nothing for it.
    func testAnItemNoLongerOnTheMenuIsDropped() {
        var meal = RoadFoodMeal()
        meal.add(sandwich)
        meal.add(milk)
        XCTAssertEqual(meal.items(from: [milk]).map(\.id), [milk.id])
    }
}
