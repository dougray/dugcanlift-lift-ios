import XCTest
import LiftCore
@testable import Lift

/// Pins what a save is allowed to throw away, which is nothing the form still
/// shows.
final class RecipeMacroEntryTests: XCTestCase {

    private func entered(_ calories: String = "", _ protein: String = "",
                         _ carbs: String = "", _ fat: String = "", _ fiber: String = "",
                         saturatedFat: String = "", sugar: String = "", sodium: String = "") -> NutritionFacts? {
        RecipeMacroEntry.entered(calories: calories, protein: protein, carbs: carbs,
                                 fat: fat, fiber: fiber,
                                 saturatedFat: saturatedFat, sugar: sugar, sodium: sodium)
    }

    /// An untouched form writes nothing. A zero here logs as a zero-calorie
    /// meal later.
    func testABlankFormEntersNothing() {
        XCTAssertNil(entered())
    }

    func testFibreIsReadFromItsOwnField() {
        XCTAssertEqual(entered("400", "30", "40", "10", "6")?.fiberG, 6)
    }

    /// Blank fibre stays nil rather than becoming a measured zero: a dish
    /// whose ingredients carry no fibre data must not claim to have none.
    func testBlankFibreStaysNilRatherThanZero() {
        XCTAssertNil(entered("400", "30", "40", "10", "")?.fiberG)
    }

    /// The editor loads all eight values from the recipe, so an imported
    /// recipe saved untouched keeps what `RecipeJSONLD` read off the page.
    func testSaturatedFatSugarAndSodiumAreReadFromTheirFields() {
        let saved = entered("400", "30", "40", "10", "6", saturatedFat: "3.5", sugar: "12", sodium: "300")
        XCTAssertEqual(saved?.saturatedFatG, 3.5)
        XCTAssertEqual(saved?.sugarG, 12)
        XCTAssertEqual(saved?.sodiumMg, 300)
        XCTAssertEqual(saved?.calories, 400, "the three sit beside the macros, not in place of any")
    }

    /// Blank is unknown for all three, and clearing a field clears the value:
    /// the field is the answer now that each has one.
    func testBlankDetailsStayNil() {
        let saved = entered("400", "30", "40", "10", "6", saturatedFat: "", sugar: " ", sodium: "")
        XCTAssertNil(saved?.saturatedFatG)
        XCTAssertNil(saved?.sugarG)
        XCTAssertNil(saved?.sodiumMg)
    }

    func testClearingFibreClearsIt() {
        XCTAssertNil(entered("400", "30", "40", "10", "", sugar: "12")?.fiberG)
    }

    /// Fibre alone is content: the form is not untouched.
    func testFibreAloneCountsAsEntered() {
        let saved = entered("", "", "", "", "6")
        XCTAssertEqual(saved?.fiberG, 6)
        XCTAssertEqual(saved?.calories, 0)
    }

    func testWhitespaceIsNotAValue() {
        XCTAssertNil(entered("  ", "  ", "  ", "  ", "  ", saturatedFat: " ", sugar: " ", sodium: " "))
    }
}
