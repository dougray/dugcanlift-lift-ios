import XCTest
@testable import Lift

/// `FoodEntryDisplay.amountText` is the one behavioral branch the whole
/// gram-based migration strategy depends on: entries with a canonical
/// `amountGrams` display it converted to whatever `ServingUnit` is
/// *currently* preferred, regardless of what was active when logged; entries
/// without one (never migrated) must keep showing their original
/// `quantity`/`servingUnit` text completely unchanged, independent of the
/// preference.
final class FoodEntryDisplayTests: XCTestCase {

    private func makeEntry(quantity: Double, servingUnit: String, amountGrams: Double?) -> FoodEntry {
        FoodEntry(
            foodRefID: "usda:174608",
            name: "Oats",
            quantity: quantity,
            servingUnit: servingUnit,
            amountGrams: amountGrams,
            nutrition: .zero,
            mealType: .breakfast
        )
    }

    func testAmountGramsDisplaysInGramsWhenGramsPreferred() {
        let entry = makeEntry(quantity: 1, servingUnit: "serving", amountGrams: 140)
        XCTAssertEqual(FoodEntryDisplay.amountText(for: entry, preferredUnit: .grams), "140 g")
    }

    func testAmountGramsConvertsToOuncesWhenOuncesPreferred() {
        let entry = makeEntry(quantity: 1, servingUnit: "serving", amountGrams: 140)
        // 140g / 28.3495 = 4.938... -> rounds to one decimal place.
        XCTAssertEqual(FoodEntryDisplay.amountText(for: entry, preferredUnit: .ounces), "4.9 oz")
    }

    func testDisplayUnitIsIndependentOfUnitActiveWhenLogged() {
        // The entry's own `servingUnit` field says "g" (as FoodSearchView
        // would set it if logged while grams was preferred), but the
        // *current* preference is ounces — amountGrams is canonical, so the
        // display must follow the current preference, not the stored field.
        let entry = makeEntry(quantity: 140, servingUnit: "g", amountGrams: 140)
        XCTAssertEqual(FoodEntryDisplay.amountText(for: entry, preferredUnit: .ounces), "4.9 oz")
    }

    func testWholeGramAmountHasNoDecimal() {
        let entry = makeEntry(quantity: 1, servingUnit: "serving", amountGrams: 200)
        XCTAssertEqual(FoodEntryDisplay.amountText(for: entry, preferredUnit: .grams), "200 g")
    }

    func testNilAmountGramsFallsBackToLegacyQuantityAndServingUnitText() {
        let entry = makeEntry(quantity: 2, servingUnit: "cup", amountGrams: nil)
        XCTAssertEqual(FoodEntryDisplay.amountText(for: entry, preferredUnit: .grams), "2 cup")
        XCTAssertEqual(FoodEntryDisplay.amountText(for: entry, preferredUnit: .ounces), "2 cup",
                        "legacy entries with no amountGrams must not react to the unit preference")
    }

    func testNilAmountGramsWithFractionalQuantityFormatsWithOneDecimal() {
        let entry = makeEntry(quantity: 1.5, servingUnit: "serving", amountGrams: nil)
        XCTAssertEqual(FoodEntryDisplay.amountText(for: entry, preferredUnit: .grams), "1.5 serving")
    }
}
