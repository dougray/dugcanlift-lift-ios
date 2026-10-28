import XCTest
@testable import Lift

final class RoadFoodAllergensTests: XCTestCase {
    private func item(_ id: String, _ allergens: [String]?) -> RoadFoodItem {
        RoadFoodItem(id: id, name: id, kcal: 300, proteinG: 20, fatG: 10, carbsG: 30, allergens: allergens)
    }

    private let nine = RoadFoodAllergens.all
    private let noShellfish = RoadFoodAllergens.all.filter { $0 != "shellfish" }

    func testAvoidingNothingShowsEverything() {
        let items = [item("a", ["milk"]), item("b", nil)]
        XCTAssertEqual(RoadFoodAllergens.filter(items, covered: nine, avoiding: []).shown, items)
        XCTAssertEqual(RoadFoodAllergens.verdict(items[0], covered: nine, avoiding: []), .clear)
    }

    func testAnItemContainingWhatIsAvoidedIsHiddenAndCounted() {
        let items = [item("bun", ["milk", "wheat"]), item("salad", []), item("wrap", ["wheat"])]
        let filtered = RoadFoodAllergens.filter(items, covered: nine, avoiding: ["milk"])
        XCTAssertEqual(filtered.shown.map(\.id), ["salad", "wrap"])
        XCTAssertEqual(filtered.hiddenCount, 1)
        XCTAssertEqual(RoadFoodAllergens.verdict(items[0], covered: nine, avoiding: ["milk", "soy"]),
                       .contains(["milk"]))
    }

    /// Never claimed free: an item the chart says nothing about stays, and says so.
    func testAnItemNotStatedIsShownAndSaidToBeNotStated() {
        let unknown = item("mystery", nil)
        let filtered = RoadFoodAllergens.filter([unknown], covered: nine, avoiding: ["milk"])
        XCTAssertEqual(filtered.shown, [unknown])
        let verdict = RoadFoodAllergens.verdict(unknown, covered: nine, avoiding: ["egg", "milk"])
        XCTAssertEqual(verdict, .notStated(["milk", "egg"]))
        XCTAssertEqual(RoadFoodAllergens.notStatedLine(verdict), "Milk and egg not stated")
    }

    /// A chart with no shellfish column says nothing about shellfish, even for
    /// an item it lists with no allergens at all.
    func testAnAllergenTheChartDoesNotCoverIsNotStatedEvenForAnEmptyList() {
        let nuggets = item("nuggets", [])
        XCTAssertEqual(RoadFoodAllergens.verdict(nuggets, covered: noShellfish, avoiding: ["shellfish"]),
                       .notStated(["shellfish"]))
        XCTAssertEqual(RoadFoodAllergens.verdict(nuggets, covered: noShellfish, avoiding: ["milk"]), .clear)
        // A chain with no chart at all: everything is not stated.
        XCTAssertEqual(RoadFoodAllergens.verdict(nuggets, covered: [], avoiding: ["milk"]), .notStated(["milk"]))
    }

    func testTheContainsLine() {
        XCTAssertEqual(RoadFoodAllergens.containsLine(item("a", ["milk", "wheat", "soy"])),
                       "Contains milk, wheat, and soy")
        XCTAssertEqual(RoadFoodAllergens.containsLine(item("a", ["tree-nuts"])), "Contains tree nuts")
        XCTAssertEqual(RoadFoodAllergens.containsLine(item("a", [])),
                       "Contains none of the allergens its chart lists")
        XCTAssertNil(RoadFoodAllergens.containsLine(item("a", nil)))
    }

    func testUnknownStringsAreDroppedAndOrderIsFixed() {
        XCTAssertEqual(RoadFoodAllergens.known(["SOY", "gluten", "milk", "milk"]), ["milk", "soy"])
    }

    func testTheAvoidListIsKeptAndEmptyStoresNoKey() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        addTeardownBlock { defaults.removePersistentDomain(forName: #function) }
        RoadFoodAllergens.save(["wheat", "milk"], to: defaults)
        XCTAssertEqual(RoadFoodAllergens.load(from: defaults), ["milk", "wheat"])
        RoadFoodAllergens.save([], to: defaults)
        XCTAssertNil(defaults.object(forKey: RoadFoodAllergens.storageKey))
    }

    func testTheFieldsDecodeAndJunkIsDropped() throws {
        let json = """
        {"id":"c","name":"C","allergensCovered":["milk","wheat","dairy"],
         "items":[{"id":"c-a","name":"A","kcal":1,"proteinG":1,"fatG":1,"carbsG":1,"allergens":["wheat","nuts"]},
                  {"id":"c-b","name":"B","kcal":1,"proteinG":1,"fatG":1,"carbsG":1}]}
        """
        let chain = try JSONDecoder().decode(RoadFoodChain.self, from: Data(json.utf8))
        XCTAssertEqual(chain.allergensCovered, ["milk", "wheat"])
        XCTAssertEqual(chain.items[0].allergens, ["wheat"])
        XCTAssertNil(chain.items[1].allergens)
    }

    /// Three different things to say, and never "Wendy's's".
    func testTheSourceNoteSaysWhatTheChartCanAndCannotSay() {
        XCTAssertEqual(RoadFoodAllergens.sourceNote(chainName: nil, hasChart: false, statesCoverage: false),
                       "This place publishes no allergen chart LIFT can read, so nothing is marked either way.")
        XCTAssertEqual(RoadFoodAllergens.sourceNote(chainName: "Taco Bell", hasChart: false, statesCoverage: false),
                       "This place publishes no allergen chart LIFT can read, so nothing is marked either way.")
        XCTAssertEqual(RoadFoodAllergens.sourceNote(chainName: "Wendy's", hasChart: true, statesCoverage: true),
                       "From the allergen chart Wendy's publishes, which doesn't cover cross-contact. Check with the restaurant.")
        XCTAssertEqual(RoadFoodAllergens.sourceNote(chainName: "Starbucks", hasChart: true, statesCoverage: false),
                       "From the allergen chart Starbucks publishes. It says what items contain, not which allergens it covers, "
                       + "so nothing is marked free of anything. It doesn't cover cross-contact either. Check with the restaurant.")
    }
}
