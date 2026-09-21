import XCTest
import LiftCore
@testable import Lift

/// Road Food's rules. A port of LIFT web's `lift/road-food.test.mjs`
/// (dugcanlift-site), test for test, so the two platforms are held to the
/// same answers; the iOS-only ones (logging a `FoodEntry`) follow.
final class RoadFoodRankingTests: XCTestCase {

    private func item(_ name: String, _ kcal: Double?, _ protein: Double?, _ sodium: Double? = nil) -> RoadFoodItem {
        RoadFoodItem(id: name, name: name, kcal: kcal, proteinG: protein, sodiumMg: sodium)
    }

    private func names(_ list: [RoadFoodItem]) -> [String] { list.map(\.name) }

    // MARK: - No goal

    func testWithNoGoalEverythingIsRankedByProteinPer100KcalAlone() {
        let r = RoadFoodRanking.rank([
            item("low", 500, 10, 100),      // 2 per 100
            item("high", 200, 40, 900),     // 20 per 100
            item("mid", 400, 30, 300),      // 7.5 per 100
            item("huge", 2000, 120, 3000),  // 6 per 100 -- no calorie cut without a goal
        ], remainingCalories: nil)
        XCTAssertEqual(r.mode, .noGoal)
        XCTAssertEqual(names(r.fits), ["high", "mid", "huge", "low"])
        XCTAssertEqual(r.over, [])
    }

    func testANonFiniteGoalIsNoGoal() {
        XCTAssertEqual(RoadFoodRanking.rank([item("a", 100, 10, 1)], remainingCalories: .nan).mode, .noGoal)
    }

    func testNoGoalMeansNoGoalWhateverThePlaceholderNumbersSay() {
        // MacroGoals' defaults (1748 kcal) are not a goal anyone chose.
        XCTAssertNil(RemainingMacros.forDay(goalIsSet: false, goalCalories: 1748, goalProteinG: 160,
                                            eaten: NutritionFacts(calories: 500, proteinG: 30)))
    }

    // MARK: - Fits and a little over

    func testEverythingFitsOneRankedGroupAndNothingOver() {
        let r = RoadFoodRanking.rank([item("a", 300, 15, 500), item("b", 200, 30, 400), item("c", 640, 40, 1000)],
                                     remainingCalories: 640)
        XCTAssertEqual(r.mode, .goal)
        XCTAssertEqual(names(r.fits), ["b", "c", "a"])
        XCTAssertEqual(r.over, [])
    }

    func testNothingFitsOnlyTheTenPercentBandIsOffered() {
        let r = RoadFoodRanking.rank([item("near", 330, 30, 500), item("far", 900, 60, 1200)],
                                     remainingCalories: 300)
        XCTAssertEqual(r.fits, [])
        XCTAssertEqual(names(r.over), ["near"])
    }

    func testADayAlreadyOverOnlyAZeroCalorieItemFitsAndNothingIsALittleOver() {
        let r = RoadFoodRanking.rank([item("cola", 0, 0, 40), item("bar", 200, 20, 180)], remainingCalories: -150)
        XCTAssertEqual(names(r.fits), ["cola"], "a zero-calorie drink still fits nothing left")
        XCTAssertEqual(r.over, [])
    }

    func testTheTenPercentBoundaryExactly() {
        let r = RoadFoodRanking.rank([
            item("exactly-left", 640, 30, 500),
            item("exactly-10", 704, 30, 500),
            item("past-10", 705, 30, 500),
        ], remainingCalories: 640)
        XCTAssertEqual(names(r.fits), ["exactly-left"])
        XCTAssertEqual(names(r.over), ["exactly-10"])
        // 30 x 1.1 is 33.000000000000004 in floating point; the comparison
        // must not let that decide it either way.
        let small = RoadFoodRanking.rank([item("33", 33, 1, 1), item("34", 34, 1, 1)], remainingCalories: 30)
        XCTAssertEqual(names(small.over), ["33"])
    }

    func testTheOverGroupIsRankedByTheSameRuleAsFits() {
        let r = RoadFoodRanking.rank([item("lean", 700, 60, 900), item("fatty", 690, 20, 900)], remainingCalories: 640)
        XCTAssertEqual(names(r.over), ["lean", "fatty"])
    }

    // MARK: - Blank stays blank

    func testMissingProteinRanksAfterEveryKnownProteinNeverAsZero() {
        let r = RoadFoodRanking.rank([
            item("unknown", 300, nil, 100),
            item("diet-cola", 0, 0, 40),
            item("some", 300, 5, 900),
        ], remainingCalories: 640)
        XCTAssertEqual(names(r.fits), ["some", "diet-cola", "unknown"])
        XCTAssertNil(RoadFoodRanking.proteinPer100(item("x", 300, nil)))
    }

    func testMissingCaloriesCannotFitAndRanksLastWithNoGoal() {
        let items = [item("no-kcal", nil, 30), item("ok", 300, 10, 1)]
        XCTAssertEqual(names(RoadFoodRanking.rank(items, remainingCalories: 640).fits), ["ok"])
        XCTAssertEqual(names(RoadFoodRanking.rank(items, remainingCalories: nil).fits), ["ok", "no-kcal"])
    }

    func testTiesGoToLowerSodiumAndMissingSodiumLosesTheTie() {
        let r = RoadFoodRanking.rank([
            item("salty", 200, 20, 1200),
            item("unlisted", 200, 20, nil),
            item("mild", 200, 20, 300),
        ], remainingCalories: 640)
        XCTAssertEqual(names(r.fits), ["mild", "salty", "unlisted"])
    }

    func testDensityNotGramsASmallHighProteinItemBeatsABigOne() {
        XCTAssertEqual(names(RoadFoodRanking.rank([item("big", 600, 45, 1), item("small", 150, 25, 1)],
                                                  remainingCalories: nil).fits), ["small", "big"])
        XCTAssertEqual(RoadFoodRanking.proteinPer100(item("x", 200, 30)), 15)
        XCTAssertEqual(RoadFoodRanking.proteinPer100(item("x", 0, 0)), 0)
        XCTAssertEqual(RoadFoodRanking.proteinPer100(item("x", 0, 5)), .infinity)
    }

    // MARK: - How old the numbers are

    func testSixCalendarMonthsIsTheLineAndAMissingDateIsSaidToBeMissing() {
        XCTAssertEqual(RoadFoodRanking.isStale(checkedOn: "2026-03-20", today: "2026-09-20"), false,
                       "exactly six months is not over")
        XCTAssertEqual(RoadFoodRanking.isStale(checkedOn: "2026-03-20", today: "2026-09-21"), true)
        XCTAssertEqual(RoadFoodRanking.isStale(checkedOn: "2026-09-20", today: "2026-09-20"), false)
        XCTAssertEqual(RoadFoodRanking.isStale(checkedOn: "2026-03-31", today: "2026-09-30"), false,
                       "end of month clamps, not rolls")
        XCTAssertEqual(RoadFoodRanking.isStale(checkedOn: "2026-03-31", today: "2026-10-01"), true)
        XCTAssertNil(RoadFoodRanking.isStale(checkedOn: nil, today: "2026-09-20"))
        XCTAssertNil(RoadFoodRanking.isStale(checkedOn: "2026-02-30", today: "2026-09-20"))
        // Across a year end, and into a leap February.
        XCTAssertEqual(RoadFoodRanking.isStale(checkedOn: "2025-08-31", today: "2026-02-28"), false)
        XCTAssertEqual(RoadFoodRanking.isStale(checkedOn: "2025-08-31", today: "2026-03-01"), true)
        XCTAssertEqual(RoadFoodRanking.isStale(checkedOn: "2027-08-31", today: "2028-02-29"), false)
    }

    // MARK: - Rules, picker

    func testPlainRulesApplyEverywhereKindedOnesOnlyToTheirKind() {
        let rules = [RoadFoodRule(text: "Grilled over fried"),
                     RoadFoodRule(text: "Bowl not tortilla", kinds: ["mexican"]),
                     RoadFoodRule(text: "Anywhere")]
        XCTAssertEqual(RoadFoodRanking.rulesFor(rules, kind: "burgers"), ["Grilled over fried", "Anywhere"])
        XCTAssertEqual(RoadFoodRanking.rulesFor(rules, kind: "mexican"),
                       ["Grilled over fried", "Bowl not tortilla", "Anywhere"])
        XCTAssertEqual(RoadFoodRanking.rulesFor(rules, kind: nil), ["Grilled over fried", "Anywhere"])
        XCTAssertEqual(RoadFoodRanking.rulesFor([], kind: "x"), [])
    }

    func testTheGasStationGetsOnlyRulesWrittenForIt() {
        let rules = [RoadFoodRule(text: "Grilled over fried"),
                     RoadFoodRule(text: "Water over soda", kinds: ["snacks", "burgers"])]
        XCTAssertEqual(RoadFoodRanking.gasStationRules(rules), ["Water over soda"])
    }

    func testRecentChainsFirstMostRecentFirstTheRestByName() {
        let chains = [RoadFoodChain(id: "c", name: "Cee", items: []),
                      RoadFoodChain(id: "a", name: "Aye", items: []),
                      RoadFoodChain(id: "b", name: "Bee", items: [])]
        let o = RoadFoodRanking.orderChains(chains, recent: ["b", "gone", "b"])
        XCTAssertEqual(o.recent.map(\.id), ["b"])
        XCTAssertEqual(o.rest.map(\.id), ["a", "c"])
        XCTAssertEqual(RoadFoodRanking.remember(["a", "b", "c"], id: "c", max: 3), ["c", "a", "b"])
        XCTAssertEqual(RoadFoodRanking.remember(["a", "b", "c"], id: "d", max: 3), ["d", "a", "b"])
        XCTAssertEqual(RoadFoodRanking.decodeRecent(RoadFoodRanking.encodeRecent(["b", "a"])), ["b", "a"])
        XCTAssertEqual(RoadFoodRanking.decodeRecent(""), [])
    }

    // MARK: - Logging (iOS)

    func testALoggedItemIsAnOrdinaryEntryAndWhatItDoesNotListIsNilNotZero() throws {
        let sandwich = RoadFoodItem(id: "sample-burger-co-grilled-test-sandwich", name: "Grilled Test Sandwich",
                                    serving: "1 sandwich", kcal: 370, proteinG: 34, fatG: 10, carbsG: 37,
                                    saturatedFatG: 2.04, sodiumMg: 930.4)
        let at = Date(timeIntervalSince1970: 1_790_000_000)
        let entry = try XCTUnwrap(RoadFoodRanking.entry(for: sandwich, chainName: "Sample Burger Co",
                                                        mealType: .lunch, loggedAt: at))
        XCTAssertEqual(entry.name, "Grilled Test Sandwich (Sample Burger Co)", "named as web names it")
        XCTAssertNil(entry.brand)
        XCTAssertEqual(entry.foodRefID, "road:sample-burger-co-grilled-test-sandwich")
        XCTAssertEqual(entry.quantity, 1)
        XCTAssertEqual(entry.servingUnit, "sandwich")
        XCTAssertNil(entry.amountGrams)
        XCTAssertEqual(entry.mealType, .lunch)
        XCTAssertEqual(entry.dayKey, DayKey.make(from: at))
        XCTAssertEqual(entry.nutrition, NutritionFacts(calories: 370, proteinG: 34, carbsG: 37, fatG: 10,
                                                       fiberG: nil, sugarG: nil, sodiumMg: 930,
                                                       saturatedFatG: 2))
        XCTAssertNil(entry.nutrition.fiberG, "not listed stays blank")
        XCTAssertNil(entry.nutrition.sugarG, "not listed stays blank")
    }

    func testAListedZeroIsKeptAsZero() throws {
        let cola = RoadFoodItem(id: "cola", name: "Diet Test Cola", kcal: 0, proteinG: 0, fatG: 0, carbsG: 0,
                                sugarG: 0, sodiumMg: 40)
        let entry = try XCTUnwrap(RoadFoodRanking.entry(for: cola, chainName: "Sample Burger Co", mealType: .snack))
        XCTAssertEqual(entry.nutrition.sugarG, 0)
        XCTAssertEqual(entry.nutrition.calories, 0)
        XCTAssertNil(entry.nutrition.saturatedFatG)
    }

    func testAProductCarriesItsBrandAndOneDecimalGrams() throws {
        let jerky = RoadFoodItem(id: "snack-sample-jerky", name: "Sample Beef Jerky", serving: "1 oz",
                                 kcal: 80.4, proteinG: 13.4, fatG: 1.2, carbsG: 5.49, fiberG: 0.6,
                                 saturatedFatG: 0.55, sugarG: 4.04, sodiumMg: 590.5,
                                 category: "jerky", brand: "Test Brand")
        let entry = try XCTUnwrap(RoadFoodRanking.entry(for: jerky, chainName: nil, mealType: .snack))
        XCTAssertEqual(entry.name, "Sample Beef Jerky")
        XCTAssertEqual(entry.brand, "Test Brand")
        XCTAssertEqual(entry.displayName, "Test Brand Sample Beef Jerky")
        XCTAssertEqual(entry.nutrition.calories, 80)
        XCTAssertEqual(entry.nutrition.proteinG, 13)
        XCTAssertEqual(entry.nutrition.carbsG, 5)
        XCTAssertEqual(entry.nutrition.fiberG, 1)
        XCTAssertEqual(try XCTUnwrap(entry.nutrition.saturatedFatG), 0.6, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(entry.nutrition.sugarG), 4.0, accuracy: 1e-9)
        XCTAssertEqual(entry.nutrition.sodiumMg, 591)
    }

    /// A `FoodEntry` cannot leave a core macro blank -- it would be stored as
    /// zero -- so an item missing one is not logged at all, and says why.
    func testMissingProteinIsNeverLoggedAsZero() {
        let wrap = RoadFoodItem(id: "wrap", name: "Mystery Wrap", kcal: 410, fatG: 16, carbsG: 44)
        XCTAssertNil(RoadFoodRanking.entry(for: wrap, chainName: "Sample Burger Co", mealType: .lunch))
        XCTAssertEqual(RoadFoodRanking.cannotLogReason(wrap), "Can't be logged: protein not listed")
        let sandwich = RoadFoodItem(id: "s", name: "S", kcal: 370, proteinG: 34, fatG: 10, carbsG: 37)
        XCTAssertNil(RoadFoodRanking.cannotLogReason(sandwich))
    }

    /// The watch resolves a recent food by id to grams and nutrition, and it
    /// cannot resolve a Road Food item, so none is offered to it.
    func testRoadFoodEntriesAreNotOfferedToTheWatch() throws {
        let sandwich = RoadFoodItem(id: "s", name: "S", kcal: 370, proteinG: 34, fatG: 10, carbsG: 37)
        let road = try XCTUnwrap(RoadFoodRanking.entry(for: sandwich, chainName: "Sample Burger Co", mealType: .lunch))
        let reference = FoodEntry(foodRefID: "usda:174608", name: "Chicken", quantity: 1, servingUnit: "serving",
                                  nutrition: NutritionFacts(calories: 200), mealType: .lunch)
        let snapshot = WatchSyncReceiver.makeSnapshot(from: [road, reference])
        XCTAssertEqual(snapshot.items.map(\.foodRefID), ["usda:174608"])
    }

    // MARK: - Remaining macros (shared with Home)

    func testRemainingIsGoalMinusEatenAndHomeReadsItTheWayItAlwaysDid() throws {
        let left = try XCTUnwrap(RemainingMacros.forDay(goalIsSet: true, goalCalories: 2000, goalProteinG: 160,
                                                        eaten: NutritionFacts(calories: 1359.3, proteinG: 105)))
        XCTAssertEqual(left.wholeCalories, 640)
        XCTAssertEqual(left.wholeProteinG, 55)
        XCTAssertEqual(left.calorieHeadline, "640 kcal left")

        let over = try XCTUnwrap(RemainingMacros.forDay(goalIsSet: true, goalCalories: 2000, goalProteinG: 160,
                                                        eaten: NutritionFacts(calories: 2150, proteinG: 170)))
        XCTAssertEqual(over.calorieHeadline, "150 kcal over")
        XCTAssertEqual(over.wholeProteinG, -10)

        let exact = try XCTUnwrap(RemainingMacros.forDay(goalIsSet: true, goalCalories: 2000, goalProteinG: 160,
                                                         eaten: NutritionFacts(calories: 2000)))
        XCTAssertEqual(exact.calorieHeadline, "0 kcal over", "unchanged from Home's own wording")
    }

    // MARK: - Display

    func testServingSplitsSoFoodsAmountLineReadsOnce() {
        XCTAssertTrue(RoadFoodRanking.servingParts("2 patties") == (2, "patties"))
        XCTAssertTrue(RoadFoodRanking.servingParts("12 fl oz") == (12, "fl oz"))
        XCTAssertTrue(RoadFoodRanking.servingParts("1 sandwich") == (1, "sandwich"))
        XCTAssertTrue(RoadFoodRanking.servingParts("large bowl") == (1, "large bowl"))
        XCTAssertTrue(RoadFoodRanking.servingParts(nil) == (1, "serving"))
    }

    func testCategoryLabelsReadAsWords() {
        XCTAssertEqual(RoadFoodRanking.categoryLabel("protein-bar"), "Protein bar")
        XCTAssertEqual(RoadFoodRanking.categoryLabel("string cheese"), "String cheese")
        XCTAssertEqual(RoadFoodRanking.categoryLabel("jerky"), "Jerky")
    }

    func testCheckDatesReadAsDatesAndNonDatesAsNothing() {
        XCTAssertEqual(RoadFoodRanking.dateText("2026-09-20", locale: Locale(identifier: "en_US")), "Sep 20, 2026")
        XCTAssertNil(RoadFoodRanking.dateText("2026-02-30"))
        XCTAssertNil(RoadFoodRanking.dateText("20 Sept"))
        XCTAssertNil(RoadFoodRanking.dateText(nil))
    }
}
