import XCTest
import LiftCore
@testable import Lift

/// A recipe Safari really handed over: BBC Good Food's chilli con carne,
/// shared from Safari on Doug's iPhone on 2026-10-07 and copied off the phone
/// from the saved recipe's source transcript (only Coach's appended note line
/// dropped). It proves the share path (`SharedRecipePage.firstRecipe`) reads a real publisher's JSON-LD, not
/// only the shapes the tests were written against. Never regenerate it from
/// this code; capture a new page instead.
final class SafariCapturedRecipeTests: XCTestCase {

    private func block() throws -> String {
        let url = try XCTUnwrap(Bundle(for: Self.self)
            .url(forResource: "safari-bbcgoodfood-chilli", withExtension: "json"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Every figure here was read off the page's JSON by hand.
    func testTheCapturedPageReadsAsTheRecipeItPublished() throws {
        let url = try XCTUnwrap(URL(string: "https://www.bbcgoodfood.com/recipes/chilli-con-carne-recipe"))
        let page = SharedRecipePage(url: url, blocks: [try block()])
        let found = try XCTUnwrap(page.firstRecipe())
        let recipe = found.recipe
        XCTAssertTrue(recipe.name.hasPrefix("Chilli con carne"), recipe.name)
        XCTAssertEqual(recipe.servings, 4)
        XCTAssertEqual(recipe.ingredientLines.count, 16)
        XCTAssertEqual(recipe.ingredientLines.first, "1 large onion")
        XCTAssertEqual(recipe.steps.count, 16)
        let perServing = try XCTUnwrap(recipe.nutritionPerServing)
        XCTAssertEqual(perServing.calories, 380, accuracy: 0.5)
        XCTAssertEqual(perServing.proteinG, 33, accuracy: 0.5)
        XCTAssertEqual(perServing.carbsG, 21.09, accuracy: 0.01)
        XCTAssertEqual(perServing.fatG, 16.08, accuracy: 0.01)
    }
}
