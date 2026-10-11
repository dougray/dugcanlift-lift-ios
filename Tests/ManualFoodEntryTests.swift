import XCTest
import SwiftData
import LiftCore
@testable import Lift

/// Adding a food by hand from food search: macros typed as they read per 100 g,
/// like LIFT web's form, then the amount eaten in the person's unit. The totals
/// are per-100 g × grams ÷ 100, blank stays blank, and what is logged is an
/// ordinary manual entry (`foodRefID` empty).
final class ManualFoodEntryTests: XCTestCase {

    private func newEntry(_ name: String = "Oat bar", unit: ServingUnit = .grams,
                          meal: MealType = .snack) -> FoodEntryEdit {
        FoodEntryEdit(newNamed: name, mealType: meal, preferredUnit: unit)
    }

    /// The four required macros, per 100 g.
    private func filled(_ edit: inout FoodEntryEdit) {
        edit.setText("250", for: .calories)
        edit.setText("10", for: .protein)
        edit.setText("40", for: .carbs)
        edit.setText("6", for: .fat)
    }

    // MARK: - Starting state

    func testANewEntryIsManualAndStartsAt100Grams() {
        let edit = newEntry()
        XCTAssertTrue(edit.isNew)
        XCTAssertTrue(edit.isManual)
        XCTAssertTrue(edit.canEditMacros)
        XCTAssertEqual(edit.mode, .weight(.grams))
        XCTAssertEqual(edit.amountText, "100")
        XCTAssertEqual(edit.amountUnitLabel, "g")
        XCTAssertEqual(edit.amount, 100)
        XCTAssertEqual(edit.name, "Oat bar")
        XCTAssertEqual(edit.mealType, .snack)
        for macro in FoodEntryEdit.Macro.allCases {
            XCTAssertEqual(edit.text(for: macro), "", "\(macro) starts blank, never 0")
        }
    }

    /// 100 g reads "3.5" oz; left alone, it is still exactly 100 g.
    func testAnUntouchedDefaultInOuncesIsExactly100Grams() throws {
        var edit = newEntry(unit: .ounces)
        XCTAssertEqual(edit.amountText, "3.5")
        XCTAssertEqual(edit.amountUnitLabel, "oz")
        filled(&edit)
        let result = try XCTUnwrap(edit.result)
        XCTAssertEqual(try XCTUnwrap(result.amountGrams), 100, accuracy: 1e-9)
        XCTAssertEqual(result.nutrition.calories, 250, accuracy: 1e-9)
        XCTAssertEqual(result.servingUnit, "oz")
    }

    // MARK: - Per 100 g, scaled to the amount

    func testPer100gMacrosScaleToGrams() throws {
        var edit = newEntry()
        filled(&edit)
        edit.amountText = "150"

        let result = try XCTUnwrap(edit.result)
        XCTAssertEqual(result.nutrition.calories, 375, accuracy: 1e-9)
        XCTAssertEqual(result.nutrition.proteinG, 15, accuracy: 1e-9)
        XCTAssertEqual(result.nutrition.carbsG, 60, accuracy: 1e-9)
        XCTAssertEqual(result.nutrition.fatG, 9, accuracy: 1e-9)
        XCTAssertEqual(result.amountGrams, 150)
        XCTAssertEqual(result.quantity, 150)
        XCTAssertEqual(result.servingUnit, "g")
    }

    func testPer100gMacrosScaleToOunces() throws {
        var edit = newEntry(unit: .ounces)
        filled(&edit)
        edit.amountText = "2"

        let result = try XCTUnwrap(edit.result)
        let grams = ServingUnit.ounces.toGrams(2)               // 56.699 g
        XCTAssertEqual(try XCTUnwrap(result.amountGrams), grams, accuracy: 1e-9)
        XCTAssertEqual(result.nutrition.calories, 250 * grams / 100, accuracy: 1e-9)
        XCTAssertEqual(result.nutrition.calories, 141.7475, accuracy: 1e-4)
        XCTAssertEqual(result.quantity, 2)
        XCTAssertEqual(result.servingUnit, "oz")
    }

    /// The fields are per 100 g, so changing the amount changes the totals and
    /// leaves what was typed exactly as typed.
    func testTheFieldsStayPer100gWhenTheAmountChanges() throws {
        var edit = newEntry()
        filled(&edit)
        edit.setText("12.55", for: .protein)
        edit.amountText = "200"
        XCTAssertEqual(edit.text(for: .calories), "250")
        XCTAssertEqual(edit.text(for: .protein), "12.55")
        XCTAssertEqual(try XCTUnwrap(edit.nutrition).calories, 500, accuracy: 1e-9)
        edit.amountText = "50"
        XCTAssertEqual(edit.text(for: .calories), "250")
        XCTAssertEqual(try XCTUnwrap(edit.nutrition).proteinG, 6.275, accuracy: 1e-9)
    }

    func testMacrosCanBeTypedBeforeTheAmountIsValid() throws {
        var edit = newEntry()
        edit.amountText = ""
        XCTAssertTrue(edit.canEditMacros, "per 100 g needs no amount to type against")
        filled(&edit)
        XCTAssertEqual(edit.text(for: .calories), "250")
        XCTAssertNil(edit.result)
        edit.amountText = "80"
        XCTAssertEqual(try XCTUnwrap(edit.result).nutrition.calories, 200, accuracy: 1e-9)
    }

    func testOptionalNutrientsScaleWithTheRest() throws {
        var edit = newEntry()
        filled(&edit)
        edit.setText("5", for: .fiber)
        edit.setText("2", for: .saturatedFat)
        edit.setText("12", for: .sugar)
        edit.setText("300", for: .sodium)
        edit.amountText = "150"

        let n = try XCTUnwrap(edit.result).nutrition
        XCTAssertEqual(try XCTUnwrap(n.fiberG), 7.5, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(n.saturatedFatG), 3, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(n.sugarG), 18, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(n.sodiumMg), 450, accuracy: 1e-9)
    }

    // MARK: - Blank stays blank

    func testBlankOptionalNutrientsAreNilNotZero() throws {
        var edit = newEntry()
        filled(&edit)
        edit.setText(" ", for: .sugar)
        let n = try XCTUnwrap(edit.result).nutrition
        XCTAssertNil(n.fiberG)
        XCTAssertNil(n.saturatedFatG)
        XCTAssertNil(n.sugarG)
        XCTAssertNil(n.sodiumMg)
    }

    func testATypedZeroStaysZero() throws {
        var edit = newEntry()
        filled(&edit)
        edit.setText("0", for: .fat)
        edit.setText("0", for: .fiber)
        edit.setText("0", for: .sodium)
        let n = try XCTUnwrap(edit.result).nutrition
        XCTAssertEqual(n.fatG, 0)
        XCTAssertEqual(n.fiberG, 0, "a typed zero is a measured zero")
        XCTAssertEqual(n.sodiumMg, 0)
    }

    // MARK: - Validation, in the editor's own words

    func testANewEntryNeedsAName() {
        var edit = newEntry("  ")
        filled(&edit)
        XCTAssertNil(edit.result)
        XCTAssertEqual(edit.problem, "Give the food a name.")
    }

    func testANewEntryNeedsAnAmountAboveZero() {
        var edit = newEntry()
        filled(&edit)
        for text in ["", "0", "-5", "abc"] {
            edit.amountText = text
            XCTAssertNil(edit.result, "amount \(text)")
            XCTAssertEqual(edit.problem, "Enter an amount above zero.", "amount \(text)")
        }
    }

    func testTheFourMacrosAreRequiredAndNeverDefaultToZero() {
        var edit = newEntry()
        XCTAssertNil(edit.result)
        XCTAssertEqual(edit.problem, "Enter calories, protein, carbs, and fat. Everything else can be left blank.")
        edit.setText("250", for: .calories)
        edit.setText("10", for: .protein)
        edit.setText("40", for: .carbs)
        XCTAssertNil(edit.result, "a blank fat is not a zero fat")
        XCTAssertEqual(edit.problem, "Enter fat. Everything else can be left blank.")
        edit.setText("6", for: .fat)
        XCTAssertNil(edit.problem)
    }

    // MARK: - Numbers

    /// The decimal pad types a comma in de_DE; `parse` reads either, in any
    /// locale, so "12,5" is 12.5 and never 125 or nil.
    func testCommaDecimalsAreRead() throws {
        var edit = newEntry()
        filled(&edit)
        edit.setText("12,5", for: .protein)
        edit.amountText = "150,0"
        let result = try XCTUnwrap(edit.result)
        XCTAssertEqual(result.nutrition.proteinG, 18.75, accuracy: 1e-9)
        XCTAssertEqual(result.amountGrams, 150)
        XCTAssertEqual(result.quantity, 150)
    }

    // MARK: - Labels

    func testFieldsSayPer100gOnlyWhenTheyAre() {
        let new = newEntry()
        XCTAssertEqual(new.fieldLabel(for: .calories), "Calories (per 100 g)")
        XCTAssertEqual(new.fieldLabel(for: .protein), "Protein (g/100g)")
        XCTAssertEqual(new.fieldLabel(for: .fiber), "Fibre (g/100g)")
        XCTAssertEqual(new.fieldLabel(for: .sodium), "Sodium (mg/100g)")

        let existing = FoodEntryEdit(name: "Bar", foodRefID: "", mealType: .snack, quantity: 1,
                                     servingUnit: "serving", amountGrams: nil,
                                     nutrition: NutritionFacts(calories: 1, proteinG: 1, carbsG: 1, fatG: 1),
                                     preferredUnit: .grams)
        XCTAssertFalse(existing.isNew)
        XCTAssertEqual(existing.fieldLabel(for: .calories), "Calories (kcal)")
        XCTAssertEqual(existing.fieldLabel(for: .sodium), "Sodium (mg)")
    }

    // MARK: - The entry it makes

    func testTheCreatedEntryIsAManualFoodEntry() throws {
        var edit = newEntry("  Oat bar ", meal: .lunch)
        filled(&edit)
        edit.setText("300", for: .sodium)
        edit.amountText = "150"
        let entry = try XCTUnwrap(edit.makeEntry())

        XCTAssertEqual(entry.foodRefID, "", "an empty reference id is what marks a manual entry")
        XCTAssertEqual(entry.name, "Oat bar")
        XCTAssertNil(entry.brand)
        XCTAssertEqual(entry.mealType, .lunch)
        XCTAssertEqual(entry.quantity, 150)
        XCTAssertEqual(entry.servingUnit, "g")
        XCTAssertEqual(entry.amountGrams, 150)
        XCTAssertEqual(entry.nutrition.calories, 375, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(entry.nutrition.sodiumMg), 450, accuracy: 1e-9)
        XCTAssertNil(entry.nutrition.fiberG)
        XCTAssertEqual(entry.dayKey, DayKey.make(from: entry.loggedAt))

        // Reopened in the ordinary editor, it is a manual entry with totals.
        let reopened = FoodEntryEdit(entry: entry, preferredUnit: .grams)
        XCTAssertTrue(reopened.isManual)
        XCTAssertFalse(reopened.isNew)
        XCTAssertEqual(reopened.text(for: .calories), "375")
    }

    func testNoEntryIsMadeWhileSomethingIsMissing() {
        var edit = newEntry()
        edit.setText("250", for: .calories)
        XCTAssertNil(edit.makeEntry())
    }

    func testTheCreatedEntrySavesToTheStore() throws {
        let context = ModelContext(LiftStore.makeContainer(inMemory: true))
        var edit = newEntry()
        filled(&edit)
        context.insert(try XCTUnwrap(edit.makeEntry()))
        try context.save()
        let stored = try XCTUnwrap(try context.fetch(FetchDescriptor<FoodEntry>()).first)
        XCTAssertEqual(stored.foodRefID, "")
        XCTAssertEqual(stored.nutrition.calories, 250, accuracy: 1e-9)
    }
}
