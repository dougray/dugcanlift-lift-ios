import XCTest
import LiftCore
@testable import Lift

/// Pins what a save is allowed to throw away, which is nothing.
final class RecipeMacroEntryTests: XCTestCase {

    private func entered(_ calories: String = "", _ protein: String = "",
                         _ carbs: String = "", _ fat: String = "", _ fiber: String = "",
                         merging existing: NutritionFacts? = nil) -> NutritionFacts? {
        RecipeMacroEntry.entered(calories: calories, protein: protein, carbs: carbs,
                                 fat: fat, fiber: fiber, merging: existing)
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

    /// The defect this file exists to stop. `RecipeJSONLD` reads fibre, sugar
    /// and sodium off a page; the editor shows only fibre. Rebuilding the
    /// facts from the visible fields alone dropped the other two on the first
    /// save after an import.
    func testSugarAndSodiumSurviveASave() {
        let imported = NutritionFacts(calories: 400, proteinG: 30, carbsG: 40,
                                      fatG: 10, fiberG: 6, sugarG: 12, sodiumMg: 300)
        let saved = entered("400", "30", "40", "10", "6", merging: imported)

        XCTAssertEqual(saved?.sugarG, 12)
        XCTAssertEqual(saved?.sodiumMg, 300)
    }

    /// Clearing the fibre field clears fibre, even when the recipe had some.
    /// Fibre has a field, so the field is the answer -- unlike sugar and
    /// sodium, which have nowhere to be cleared from.
    func testClearingFibreClearsIt() {
        let existing = NutritionFacts(calories: 400, proteinG: 30, carbsG: 40,
                                      fatG: 10, fiberG: 6, sugarG: 12)
        let saved = entered("400", "30", "40", "10", "", merging: existing)

        XCTAssertNil(saved?.fiberG)
        XCTAssertEqual(saved?.sugarG, 12, "sugar has no field, so it is still carried")
    }

    /// Fibre alone is content: the form is not untouched.
    func testFibreAloneCountsAsEntered() {
        let saved = entered("", "", "", "", "6")
        XCTAssertEqual(saved?.fiberG, 6)
        XCTAssertEqual(saved?.calories, 0)
    }

    func testWhitespaceIsNotAValue() {
        XCTAssertNil(entered("  ", "  ", "  ", "  ", "  "))
    }
}
