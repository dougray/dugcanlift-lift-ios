import XCTest
import LiftCore
@testable import Lift

/// What a person reads for saturated fat, sugar and sodium: nothing invented
/// for a food that did not record them, and a day's total that says when it
/// covers only some of the foods.
final class NutrientDetailsDisplayTests: XCTestCase {

    private let english = Locale(identifier: "en_US")

    private func facts(saturatedFat: Double? = nil, sugar: Double? = nil, sodium: Double? = nil) -> NutritionFacts {
        NutritionFacts(calories: 100, proteinG: 5, carbsG: 10, fatG: 3,
                       sugarG: sugar, sodiumMg: sodium, saturatedFatG: saturatedFat)
    }

    func testAnEntryLineShowsOnlyWhatWasRecorded() {
        XCTAssertEqual(NutrientDetailsDisplay.entryLine(facts(saturatedFat: 3.14, sugar: 14.676, sodium: 1840.4), locale: english),
                       "Sat fat 3.1 g - Sugar 14.7 g - Sodium 1,840 mg")
        XCTAssertEqual(NutrientDetailsDisplay.entryLine(facts(sodium: 540), locale: english), "Sodium 540 mg")
        XCTAssertNil(NutrientDetailsDisplay.entryLine(facts()), "no line at all, never zeros")
    }

    func testARecordedZeroIsShown() {
        XCTAssertEqual(NutrientDetailsDisplay.entryLine(facts(sugar: 0), locale: english), "Sugar 0 g")
    }

    func testDayTotalsSayHowManyFoodsTheyCover() {
        let day = [facts(sugar: 5, sodium: 890.4), facts(), facts(sugar: 39),
                   facts(sodium: 500), facts(sodium: 449.9)]
        let totals = NutrientDetailsDisplay.dayTotals(day, locale: english)
        XCTAssertEqual(totals, [
            .init(nutrient: .sugar, value: "44 g", coverage: "from 2 of 5 foods"),
            .init(nutrient: .sodium, value: "1,840 mg", coverage: "from 3 of 5 foods"),
        ], "saturated fat, which no food recorded, is left out rather than shown as 0")
    }

    func testATotalEveryFoodRecordedCarriesNoCoverageNote() {
        let totals = NutrientDetailsDisplay.dayTotals([facts(saturatedFat: 1.25), facts(saturatedFat: 2)], locale: english)
        XCTAssertEqual(totals, [.init(nutrient: .saturatedFat, value: "3.3 g", coverage: nil)])
    }

    func testNoFoodRecordingAnyShowsNothing() {
        XCTAssertEqual(NutrientDetailsDisplay.dayTotals([facts(), facts()]), [])
        XCTAssertEqual(NutrientDetailsDisplay.dayTotals([]), [])
    }

    /// The same rounding a coach reads in the link: half-up, summed unrounded.
    func testRoundingMatchesTheShareLink() {
        XCTAssertEqual(NutrientDetailsDisplay.Nutrient.sugar.formatted(0.25, locale: english), "0.3 g")
        XCTAssertEqual(NutrientDetailsDisplay.Nutrient.sodium.formatted(2.5, locale: english), "3 mg")
        let totals = NutrientDetailsDisplay.dayTotals([facts(sodium: 0.4), facts(sodium: 0.4)], locale: english)
        XCTAssertEqual(totals.first?.value, "1 mg", "0.8 rounds to 1; rounding each first would say 0")
    }
}
