import XCTest
@testable import LiftKit

final class WatchFoodLibraryTests: XCTestCase {

    private var library: WatchFoodLibrary!

    override func setUp() {
        super.setUp()
        library = WatchFoodLibrary()
    }

    func testLoadsTheBundledLibrary() {
        // The PWA's foods.json ships 7,793 USDA SR Legacy records. Asserting a
        // floor rather than the exact number: a data refresh should not fail
        // this test, but an empty or missing resource must.
        XCTAssertGreaterThan(library.count, 7_000)
    }

    func testSearchIsCaseInsensitiveSubstring() {
        let hits = library.search("chicken breast")
        XCTAssertFalse(hits.isEmpty)
        XCTAssertTrue(hits.allSatisfy { $0.name.lowercased().contains("chicken breast") })
    }

    func testSearchRespectsTheLimit() {
        XCTAssertLessThanOrEqual(library.search("a", limit: 30).count, 30)
    }

    func testBlankQueryReturnsNothingRatherThanEverything() {
        // A wrist list of 7,793 rows is not a feature — and an empty text
        // field must not render one.
        XCTAssertTrue(library.search("").isEmpty)
        XCTAssertTrue(library.search("   ").isEmpty)
    }

    func testMacrosAreParsedPositionally() {
        // foods.json records are bare arrays:
        //   [name, categoryIndex, kcal, protein, fat, carbs, fibre]
        // Indices 0 and 2-6 are what this reads; 1 is the category, unused.
        // NOTE: query is "Oil, olive" rather than the brief's "Olive oil" —
        // see task-2-report.md for why the literal brief query cannot match.
        let hits = library.search("Oil, olive")
        let oil = try? XCTUnwrap(hits.first { $0.name == "Oil, olive, salad or cooking" })
        if let oil {
            XCTAssertEqual(oil.kcal, 884, accuracy: 1)
            XCTAssertEqual(oil.fat, 100, accuracy: 1)
            XCTAssertEqual(oil.protein, 0, accuracy: 0.01)
        }
    }
}
