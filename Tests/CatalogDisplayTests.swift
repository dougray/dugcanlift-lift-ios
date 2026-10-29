import XCTest
import LiftCore
import LiftReference
@testable import Lift

/// The catalogue's three cross-build rules (see `CatalogDisplay`): the whole
/// catalogue with no search typed, whole numbers rounded rather than truncated,
/// and a servings count asked for whenever the source states no yield.
///
/// The catalogue tests read the real bundled `recipes.db` through
/// `ReferenceDatabase.shared`, because the defects were about what that data
/// produced on screen: a first page of 60, and Beef Pot Pie's 898.1 kcal
/// divided by 4 printing as 224.
final class CatalogDisplayTests: XCTestCase {

    // MARK: - The whole catalogue

    func testTheOpeningListIsTheWholeCatalogue() async throws {
        let total = try await ReferenceDatabase.shared.recipeCount()
        let browsed = try await ReferenceDatabase.shared.browseRecipes(limit: CatalogDisplay.browseLimit)

        XCTAssertGreaterThanOrEqual(total, 622)
        XCTAssertEqual(browsed.count, total, "every recipe should be on the opening list")
        XCTAssertLessThan(total, CatalogDisplay.browseLimit,
                          "the limit is a ceiling: the catalogue has outgrown it")
        XCTAssertEqual(Set(browsed.map(\.id)).count, total, "no recipe listed twice")
    }

    func testTheKitsDefaultPageIsWhyTheLimitIsPassed() async throws {
        let firstPage = try await ReferenceDatabase.shared.browseRecipes()
        let whole = try await ReferenceDatabase.shared.browseRecipes(limit: CatalogDisplay.browseLimit)

        XCTAssertEqual(firstPage.count, 60)
        // Something late in the alphabet: off the first page, on the whole list.
        let late = try XCTUnwrap(whole.first { $0.recipe.name.hasPrefix("W") },
                                 "expected a recipe starting with W")
        XCTAssertFalse(firstPage.contains { $0.id == late.id })
    }

    func testTheWholeListArrivesWithItsIngredients() async throws {
        // The kit attaches every row's ingredients in one query; this checks
        // the rows came back with them rather than empty.
        let whole = try await ReferenceDatabase.shared.browseRecipes(limit: CatalogDisplay.browseLimit)
        let withIngredients = whole.filter { !$0.ingredientLines.isEmpty }
        XCTAssertGreaterThan(withIngredients.count, whole.count * 9 / 10)
    }

    // MARK: - Rounding

    func testWholeNumbersRoundHalfAwayFromZero() {
        XCTAssertEqual(CatalogDisplay.whole(224.5), "225")
        XCTAssertEqual(CatalogDisplay.whole(224.525), "225")
        XCTAssertEqual(CatalogDisplay.whole(224.49), "224")
        XCTAssertEqual(CatalogDisplay.whole(17.8), "18")
        XCTAssertEqual(CatalogDisplay.whole(0.5), "1")
        XCTAssertEqual(CatalogDisplay.whole(0), "0")
        XCTAssertEqual(CatalogDisplay.whole(-0.5), "-1")
    }

    func testANonNumberIsADashNotAZero() {
        XCTAssertEqual(CatalogDisplay.whole(.nan), "—")
        XCTAssertEqual(CatalogDisplay.whole(.infinity), "—")
    }

    func testTheListRowRounds() throws {
        let recipe = try Self.recipe(#""servings": 2, "caloriesPerServing": 224.5"#)
        XCTAssertEqual(CatalogDisplay.listSummary(recipe), "225 kcal per serving")
    }

    func testTheListRowSaysWhenThereIsNoPortion() throws {
        XCTAssertEqual(CatalogDisplay.listSummary(try Self.recipe(#""caloriesTotal": 900"#)),
                       "Macros for the whole dish")
        XCTAssertEqual(CatalogDisplay.listSummary(try Self.recipe("")), "No macros")
    }

    func testBeefPotPieAtFourServingsReads225() async throws {
        let found = try await ReferenceDatabase.shared.catalogRecipe(id: "gutenberg-26558:beef-pot-pie")
        let entry = try XCTUnwrap(found)
        let recipe = entry.recipe
        XCTAssertNil(recipe.servings)
        XCTAssertTrue(CatalogDisplay.asksForServings(recipe))

        let servings = CatalogDisplay.startingServings(recipe)
        XCTAssertEqual(servings, 4)
        let facts = try XCTUnwrap(recipe.nutrition(servings: servings))
        // 898.1 / 4 = 224.525, which truncation printed as 224.
        XCTAssertEqual(CatalogDisplay.macroLine(facts), "225 kcal · P 10 · C 18 · F 13")
    }

    func testRoundingIsDisplayOnly() async throws {
        let found = try await ReferenceDatabase.shared.catalogRecipe(id: "gutenberg-26558:beef-pot-pie")
        let entry = try XCTUnwrap(found)
        let saved = entry.makeRecipe(
            servings: CatalogDisplay.servingsToSave(entry.recipe, chosen: 4)).recipe
        let calories = try XCTUnwrap(saved.nutritionPerServing?.calories)
        XCTAssertEqual(calories, 898.1 / 4, accuracy: 1e-9)
    }

    // MARK: - Servings

    func testANoYieldRecipeWithoutMacrosAsksForServings() throws {
        let recipe = try Self.recipe("")
        XCTAssertFalse(recipe.needsServings, "nothing to divide")
        XCTAssertTrue(CatalogDisplay.asksForServings(recipe), "but a count to choose")
        XCTAssertNil(recipe.nutrition(servings: 4), "so no per-serving line")
        XCTAssertEqual(CatalogDisplay.servingsNote(recipe),
                       "This book states no yield. Set how many it serves.")
    }

    func testANoYieldRecipeWithMacrosAsksAndSaysTheyDivide() throws {
        let recipe = try Self.recipe(#""caloriesTotal": 900"#)
        XCTAssertTrue(CatalogDisplay.asksForServings(recipe))
        XCTAssertTrue(CatalogDisplay.servingsNote(recipe).contains("whole dish"))
    }

    func testAStatedYieldIsNeverAsked() throws {
        let recipe = try Self.recipe(#""servings": 6, "caloriesPerServing": 300"#)
        XCTAssertFalse(CatalogDisplay.asksForServings(recipe))
        XCTAssertEqual(CatalogDisplay.startingServings(recipe), 6)
        XCTAssertEqual(CatalogDisplay.servingsToSave(recipe, chosen: 2), 6)
    }

    func testTheChosenCountIsWhatIsSaved() throws {
        let recipe = try Self.recipe("")
        XCTAssertEqual(CatalogDisplay.servingsToSave(recipe, chosen: 3), 3)
    }

    func testEveryNoYieldRecipeInTheCatalogueAsks() async throws {
        let whole = try await ReferenceDatabase.shared.browseRecipes(limit: CatalogDisplay.browseLimit)
        let noYield = whole.map(\.recipe).filter { $0.servings == nil }
        let withoutMacros = noYield.filter { $0.nutrition(servings: 4) == nil }

        XCTAssertFalse(withoutMacros.isEmpty,
                       "the catalogue has no-yield recipes without macros; the old rule hid their stepper")
        for recipe in noYield {
            XCTAssertTrue(CatalogDisplay.asksForServings(recipe), recipe.name)
        }
    }

    // MARK: - Fixtures

    /// `CatalogRecipe` has no public initializer, so a synthetic one is decoded,
    /// as `FoodRecord` is elsewhere in these tests. `extra` is JSON members
    /// added to the required ones.
    private static func recipe(_ extra: String) throws -> CatalogRecipe {
        let members = [
            #""id": "test:recipe", "name": "Test recipe", "nutritionIsEstimated": false"#,
            #""steps": "", "source": "test", "license": "test", "attribution": "test""#,
            extra,
        ].filter { !$0.isEmpty }.joined(separator: ", ")
        return try JSONDecoder().decode(CatalogRecipe.self, from: Data("{\(members)}".utf8))
    }
}
