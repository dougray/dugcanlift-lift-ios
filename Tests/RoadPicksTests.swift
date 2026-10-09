import XCTest
import LiftCore
@testable import Lift

/// A coach's road picks, at the end where they are shown: the ordering
/// partition, what an unknown id does, and the words.
///
/// A port of LIFT web's `lift/road-food.test.mjs` "A coach's picks" block
/// (dugcanlift-site), test for test, so a lifter reading their phone and their
/// browser sees the same list in the same order.
final class RoadPicksTests: XCTestCase {

    private func item(_ id: String, _ kcal: Double?, _ protein: Double?,
                      _ sodium: Double? = nil) -> RoadFoodItem {
        RoadFoodItem(id: id, name: id, kcal: kcal, proteinG: protein, sodiumMg: sodium)
    }

    private func names(_ list: [RoadFoodItem]) -> [String] { list.map(\.name) }

    // MARK: - The partition

    func testPicksGoToTheTopOfAGroupAndChangeNothingUnderneath() {
        let items = [
            item("a", 300, 15, 500),   // 5 per 100
            item("b", 200, 30, 400),   // 15
            item("c", 640, 40, 1000),  // 6.25
            item("d", 100, 2, 200),    // 2
        ]
        let plain = RoadFoodRanking.rank(items, remainingCalories: 640)
        XCTAssertEqual(names(plain.fits), ["b", "c", "a", "d"])

        let picked = RoadFoodRanking.withPicks(plain, ids: ["a", "d"])
        XCTAssertEqual(names(picked.fits), ["a", "d", "b", "c"])
        XCTAssertEqual(picked.picked, ["a", "d"])
        XCTAssertEqual(picked.mode, .goal)
        // Within each part the nutrition order is exactly what it was: the
        // picks in their own order, then everything else in theirs.
        XCTAssertEqual(Array(names(picked.fits).prefix(2)),
                       names(plain.fits).filter { $0 == "a" || $0 == "d" })
        XCTAssertEqual(Array(names(picked.fits).dropFirst(2)),
                       names(plain.fits).filter { $0 != "a" && $0 != "d" })
    }

    func testNoPicksAtAllLeavesTheRankingExactlyAsItWas() {
        let items = [item("a", 300, 15, 500), item("b", 200, 30, 400), item("c", 700, 60, 100)]
        let plain = RoadFoodRanking.rank(items, remainingCalories: 640)
        let picked = RoadFoodRanking.withPicks(plain, ids: [])
        XCTAssertEqual(picked, plain)
        XCTAssertTrue(picked.picked.isEmpty)
    }

    func testWithNoGoalThePicksLeadTheOneRankedList() {
        let items = [item("a", 500, 10, 100), item("b", 200, 40, 900), item("c", 400, 30, 300)]
        let picked = RoadFoodRanking.withPicks(
            RoadFoodRanking.rank(items, remainingCalories: nil), ids: ["a"])
        XCTAssertEqual(picked.mode, .noGoal)
        XCTAssertEqual(names(picked.fits), ["a", "b", "c"])
    }

    // MARK: - The fit rule is the day talking, not the coach

    func testAPickThatIsALittleOverStaysALittleOver() {
        let items = [item("fits", 300, 15, 500), item("over", 700, 60, 100)]
        let picked = RoadFoodRanking.withPicks(
            RoadFoodRanking.rank(items, remainingCalories: 640), ids: ["over"])
        XCTAssertEqual(names(picked.fits), ["fits"])
        XCTAssertEqual(names(picked.over), ["over"], "floated to the top of its own group, not out of it")
        XCTAssertEqual(picked.picked, ["over"])
    }

    func testAnItemTooFarOverIsHiddenWhetherOrNotItWasPicked() {
        let items = [item("fits", 300, 15, 500), item("way-over", 2000, 60, 100)]
        let picked = RoadFoodRanking.withPicks(
            RoadFoodRanking.rank(items, remainingCalories: 640), ids: ["way-over"])
        XCTAssertEqual(names(picked.fits), ["fits"])
        XCTAssertEqual(picked.over, [])
        XCTAssertTrue(picked.picked.isEmpty, "a pick nobody can see is not counted as shown")
    }

    // MARK: - An id this build does not know

    func testAnIdTheBundledDataDoesNotHaveIsSkippedSilently() {
        let items = [item("a", 300, 15, 500), item("b", 200, 30, 400)]
        let picked = RoadFoodRanking.withPicks(
            RoadFoodRanking.rank(items, remainingCalories: 640), ids: ["gone-2019", "a", ""])
        XCTAssertEqual(names(picked.fits), ["a", "b"], "nothing is added, and nothing is dropped")
        XCTAssertEqual(picked.picked, ["a"], "only what is here is counted")
    }

    func testPickCountCountsAPlaceWithoutDrawingItsList() {
        let items = [item("a", 1, 1, 1), item("b", 1, 1, 1)]
        XCTAssertEqual(RoadFoodRanking.pickCount(items, ids: ["b", "gone"]), 1)
        XCTAssertEqual(RoadFoodRanking.pickCount(items, ids: []), 0)
        XCTAssertEqual(RoadFoodRanking.pickCount([], ids: ["a"]), 0)
    }

    // MARK: - Against the file this build actually ships

    func testTheFixturesPicksResolveAtThreePlacesAndExactlyOneIsUnknown() throws {
        let catalog = try XCTUnwrap(RoadFoodCatalog.bundled(
            in: Bundle(for: RoadPicksTests.self))?.catalog)
        let ids = [
            "wendys-large-chili",
            "wendys-grilled-chicken-ranch-wrap",
            "chickfila-8-ct-grilled-nuggets",
            "chickfila-grilled-filet",
            "snack-jack-links-original-beef-jerky",
            "wendys-item-withdrawn-2019",
        ]
        let known = Set(catalog.chains.flatMap(\.items).map(\.id))
            .union(catalog.snacks.map(\.id))
        XCTAssertEqual(ids.filter { !known.contains($0) }, ["wendys-item-withdrawn-2019"],
                       "the deliberate one, so the skip rule is exercised by the fixture itself")

        let chains = catalog.chains.filter { RoadFoodRanking.pickCount($0.items, ids: ids) > 0 }
        XCTAssertEqual(chains.map(\.id), ["wendys", "chickfila"])
        XCTAssertEqual(RoadFoodRanking.pickCount(catalog.snacks, ids: ids), 1,
                       "and a gas-station snack, which belongs to no chain")
    }

    // MARK: - Storage

    private func defaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let suite = "road-picks-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { return XCTFail("no suite") }
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    func testPicksAreStoredWholeAndReadBackInTheCoachsOrder() {
        defaults { store in
            XCTAssertNil(RoadPicks.load(from: store))
            XCTAssertEqual(RoadPicks.accept(ids: ["b", "a"], from: "Doug", in: store), 2)
            let picks = RoadPicks.load(from: store)
            XCTAssertEqual(picks?.ids, ["b", "a"], "the order the coach ticked them, not sorted")
            XCTAssertEqual(picks?.from, "Doug")
        }
    }

    func testANewPlanReplacesThePicksWholeAndOneWithNoneLeavesThemAlone() {
        defaults { store in
            RoadPicks.accept(ids: ["a", "b"], from: "Doug", in: store)
            RoadPicks.accept(ids: ["c"], from: "Doug", in: store)
            XCTAssertEqual(RoadPicks.load(from: store)?.ids, ["c"],
                           "the newest send is the coach's current answer, whole")
            // No key: silence about picks, not a retraction. Every older Coach
            // and every "here is a recipe" send looks exactly like this.
            XCTAssertEqual(RoadPicks.accept(ids: [], from: "Doug", in: store), 0)
            XCTAssertEqual(RoadPicks.load(from: store)?.ids, ["c"])
        }
    }

    func testClearingIsThisPhonesOwnAction() {
        defaults { store in
            RoadPicks.accept(ids: ["a"], from: "Doug", in: store)
            RoadPicks.clear(in: store)
            XCTAssertNil(RoadPicks.load(from: store))
            XCTAssertNil(RoadPicks.decode(Data()), "what @AppStorage hands a view after a clear")
        }
    }

    func testJunkIsReadLenientlyRatherThanRefused() {
        XCTAssertEqual(RoadPickLink.normalise(["a", "a", "", "  b ", " "]), ["a", "b"])
        XCTAssertEqual(RoadPickLink.normalise([]), [])
        defaults { store in
            XCTAssertEqual(RoadPicks.accept(ids: ["  ", ""], from: "Doug", in: store), 0,
                           "a list of blanks is no picks, not an empty pick")
            XCTAssertNil(RoadPicks.load(from: store))
        }
    }

    // MARK: - The words

    func testTheLabelNamesTheCoachOrSaysYourCoach() {
        XCTAssertEqual(RoadPicks(ids: ["a"], from: "Doug").label("picks"), "Doug’s picks")
        XCTAssertEqual(RoadPicks(ids: ["a"], from: "Doug").label("pick"), "Doug’s pick")
        XCTAssertEqual(RoadPicks(ids: ["a"], from: "").label("picks"), "Your coach’s picks")
        XCTAssertEqual(RoadPicks.label("picks", from: nil), "Your coach’s picks")
        // A name with spaces around it is the same coach, not a different one.
        defaults { store in
            RoadPicks.accept(ids: ["a"], from: "  Doug  ", in: store)
            XCTAssertEqual(RoadPicks.load(from: store)?.label("picks"), "Doug’s picks")
        }
    }

    /// The same check LIFT web's own tests make on the two strings, and the
    /// one `LiftImbalance` and the nutrient lines are held to: shown, never
    /// targeted. A pick is a label on what a coach marked, and nothing
    /// anywhere judges what was eaten against it.
    func testNothingInTheseLinesTellsALifterWhatToDo() {
        let lines = [RoadPicks(ids: ["a"], from: "Doug").label("picks"),
                     RoadPicks(ids: ["a"], from: "Doug").label("pick"),
                     "Your coach’s picks are first, marked. Nothing else is moved, and nothing "
                     + "that fits is hidden."]
        for line in lines {
            for word in ["should", "must", "avoid", "bad", "instead of", "better", "worse",
                         "too much", "limit", "cheat"] {
                XCTAssertFalse(line.lowercased().contains(word), "\(word) in: \(line)")
            }
        }
    }
}
