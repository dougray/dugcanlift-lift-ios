import XCTest
import SwiftData
import LiftCore
@testable import Lift

/// Editing a logged food: how a new amount rescales what was stored, which
/// entries let the macros be typed, and that blank never becomes zero.
final class FoodEntryEditTests: XCTestCase {

    private let facts = NutritionFacts(calories: 300, proteinG: 24, carbsG: 30, fatG: 9,
                                       fiberG: 6, sugarG: 12, sodiumMg: 450)

    private func gramEntry(_ grams: Double = 150, unit: ServingUnit = .grams,
                           nutrition: NutritionFacts? = nil) -> FoodEntryEdit {
        FoodEntryEdit(name: "Greek yoghurt", foodRefID: "usda:170903", mealType: .breakfast,
                      quantity: unit.fromGrams(grams), servingUnit: unit.abbreviation,
                      amountGrams: grams, nutrition: nutrition ?? facts, preferredUnit: unit)
    }

    private func assertFacts(_ actual: NutritionFacts?, _ expected: NutritionFacts,
                             file: StaticString = #filePath, line: UInt = #line) {
        guard let actual else { return XCTFail("no nutrition", file: file, line: line) }
        XCTAssertEqual(actual.calories, expected.calories, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(actual.proteinG, expected.proteinG, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(actual.carbsG, expected.carbsG, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(actual.fatG, expected.fatG, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(actual.fiberG == nil, expected.fiberG == nil, "fibre nil-ness", file: file, line: line)
        if let a = actual.fiberG, let e = expected.fiberG { XCTAssertEqual(a, e, accuracy: 1e-9, file: file, line: line) }
        XCTAssertEqual(actual.sugarG == nil, expected.sugarG == nil, "sugar nil-ness", file: file, line: line)
        if let a = actual.sugarG, let e = expected.sugarG { XCTAssertEqual(a, e, accuracy: 1e-9, file: file, line: line) }
        XCTAssertEqual(actual.sodiumMg == nil, expected.sodiumMg == nil, "sodium nil-ness", file: file, line: line)
        if let a = actual.sodiumMg, let e = expected.sodiumMg { XCTAssertEqual(a, e, accuracy: 1e-9, file: file, line: line) }
    }

    // MARK: - Grams

    func testChanging150gTo200gScalesEveryValueByFourThirds() throws {
        var edit = gramEntry()
        XCTAssertEqual(edit.mode, .weight(.grams))
        XCTAssertEqual(edit.amountText, "150")
        edit.amountText = "200"

        let result = try XCTUnwrap(edit.result)
        assertFacts(result.nutrition, facts.scaled(by: 4.0 / 3.0))
        XCTAssertEqual(result.nutrition.calories, 400, accuracy: 1e-9)
        XCTAssertEqual(result.amountGrams, 200)
        XCTAssertEqual(result.quantity, 200)
        XCTAssertEqual(result.servingUnit, "g")
    }

    /// The same arithmetic `FoodSearchView.log` does on log: a food's per-100 g
    /// values times grams. Editing must land where logging that amount would.
    func testAnEditedAmountMatchesLoggingThatAmountFresh() throws {
        let per100 = NutritionFacts(calories: 97, proteinG: 9, carbsG: 3.6, fatG: 5, fiberG: nil)
        var edit = gramEntry(150, nutrition: per100.scaled(by: 1.5))
        edit.amountText = "85"
        assertFacts(edit.result?.nutrition, per100.scaled(by: 0.85))
        XCTAssertNil(edit.result?.nutrition.fiberG, "no fibre data stays no fibre data")
    }

    func testOuncesAreTypedInOuncesAndStoredAsGrams() throws {
        var edit = gramEntry(141.7475, unit: .ounces)   // 5 oz
        XCTAssertEqual(edit.amountText, "5")
        XCTAssertEqual(edit.amountUnitLabel, "oz")
        edit.amountText = "10"
        let result = try XCTUnwrap(edit.result)
        XCTAssertEqual(try XCTUnwrap(result.amountGrams), 283.495, accuracy: 1e-9)
        XCTAssertEqual(result.quantity, 10)
        XCTAssertEqual(result.servingUnit, "oz")
        XCTAssertEqual(result.nutrition.calories, 600, accuracy: 1e-9)
    }

    /// 140 g reads as "4.9" oz. Saving without touching it must not reread the
    /// rounded text and shave the entry to 138.9 g.
    func testAnUntouchedRoundedAmountChangesNothing() throws {
        let edit = gramEntry(140, unit: .ounces)
        XCTAssertEqual(edit.amountText, "4.9")
        let result = try XCTUnwrap(edit.result)
        XCTAssertEqual(result.amountGrams, 140)
        XCTAssertEqual(result.nutrition, facts)
    }

    // MARK: - Servings

    func testServingsScaleByTheCountAndKeepTheWord() throws {
        var edit = FoodEntryEdit(name: "Chilli", foodRefID: "recipe:\(UUID().uuidString)", mealType: .dinner,
                                 quantity: 2, servingUnit: "servings", amountGrams: nil,
                                 nutrition: facts, preferredUnit: .grams)
        XCTAssertEqual(edit.mode, .servings)
        XCTAssertEqual(edit.amountText, "2")
        edit.amountText = "1"
        XCTAssertEqual(edit.amountUnitLabel, "serving")

        let result = try XCTUnwrap(edit.result)
        assertFacts(result.nutrition, facts.scaled(by: 0.5))
        XCTAssertEqual(result.quantity, 1)
        XCTAssertEqual(result.servingUnit, "serving")
        XCTAssertNil(result.amountGrams, "a servings entry does not grow a gram amount")
    }

    func testAnOddUnitIsLeftAlone() throws {
        var edit = FoodEntryEdit(name: "Toast", foodRefID: "usda:1", mealType: .breakfast,
                                 quantity: 2, servingUnit: "slice", amountGrams: nil,
                                 nutrition: facts, preferredUnit: .grams)
        edit.amountText = "3"
        XCTAssertEqual(edit.result?.servingUnit, "slice")
        XCTAssertEqual(edit.result?.nutrition.calories ?? 0, 450, accuracy: 1e-9)
    }

    func testACommaDecimalReads() throws {
        var edit = FoodEntryEdit(name: "Oats", foodRefID: "usda:2", mealType: .breakfast,
                                 quantity: 1, servingUnit: "serving", amountGrams: nil,
                                 nutrition: facts, preferredUnit: .grams)
        edit.amountText = "1,5"
        XCTAssertEqual(edit.result?.quantity, 1.5)
    }

    func testABlankOrZeroAmountCannotBeSaved() {
        var edit = gramEntry()
        edit.amountText = ""
        XCTAssertNil(edit.result)
        edit.amountText = "0"
        XCTAssertNil(edit.result)
        XCTAssertNotNil(edit.problem)
    }

    // MARK: - Meal, and what is not editable

    func testChangingTheMealKeepsEverythingElse() throws {
        var edit = gramEntry()
        edit.mealType = .snack
        let result = try XCTUnwrap(edit.result)
        XCTAssertEqual(result.mealType, .snack)
        XCTAssertEqual(result.amountGrams, 150)
        XCTAssertEqual(result.nutrition, facts)
    }

    func testAReferenceFoodsMacrosAndNameCannotBeTyped() throws {
        var edit = gramEntry()
        XCTAssertFalse(edit.isManual)
        XCTAssertFalse(edit.canEditMacros)
        edit.setText("5", for: .calories)
        edit.name = "Something else"
        let result = try XCTUnwrap(edit.result)
        XCTAssertEqual(result.nutrition.calories, 300)
        XCTAssertEqual(result.name, "Greek yoghurt")
    }

    // MARK: - Manual entries

    private func manualEntry(fiber: Double? = 6) -> FoodEntryEdit {
        var n = facts
        n.fiberG = fiber
        return FoodEntryEdit(name: "Protein bar", foodRefID: "", mealType: .snack,
                             quantity: 1, servingUnit: "serving", amountGrams: nil,
                             nutrition: n, preferredUnit: .grams)
    }

    func testAManualEntrysNameAndMacrosAreTyped() throws {
        var edit = manualEntry()
        XCTAssertTrue(edit.canEditMacros)
        edit.name = "  Flapjack "
        edit.setText("210", for: .calories)
        edit.setText("12.5", for: .protein)

        let result = try XCTUnwrap(edit.result)
        XCTAssertEqual(result.name, "Flapjack")
        XCTAssertEqual(result.nutrition.calories, 210)
        XCTAssertEqual(result.nutrition.proteinG, 12.5)
        XCTAssertEqual(result.nutrition.carbsG, 30, "an untyped macro keeps its value")
        XCTAssertEqual(result.nutrition.sugarG, 12, "sugar has no field and is carried, not dropped")
    }

    func testABlankFibreStaysNil() throws {
        var edit = manualEntry()
        edit.setText("", for: .fiber)
        XCTAssertEqual(edit.text(for: .fiber), "")
        let result = try XCTUnwrap(edit.result)
        XCTAssertNil(result.nutrition.fiberG, "blank is unknown, never a measured zero")

        let untouched = try XCTUnwrap(manualEntry(fiber: nil).result)
        XCTAssertNil(untouched.nutrition.fiberG)
        XCTAssertEqual(manualEntry(fiber: nil).text(for: .fiber), "")
    }

    func testABlankRequiredMacroBlocksSaveRatherThanWritingZero() {
        var edit = manualEntry()
        edit.setText("", for: .protein)
        XCTAssertNil(edit.result)
        XCTAssertEqual(edit.problem, "Enter protein — only fibre can be left blank.")
        edit.setText("0", for: .protein)
        XCTAssertEqual(edit.result?.nutrition.proteinG, 0, "a typed zero is a zero")
    }

    func testAManualEntryNeedsAName() {
        var edit = manualEntry()
        edit.name = "   "
        XCTAssertNil(edit.result)
    }

    /// Fields show totals for the amount on screen, typing fixes them there, and
    /// a later amount change scales from that point.
    func testTypedMacrosAreTotalsForTheAmountOnScreen() throws {
        var edit = manualEntry()
        edit.amountText = "2"
        XCTAssertEqual(edit.text(for: .calories), "600", "doubling the servings doubles what the field shows")

        edit.setText("500", for: .calories)
        var result = try XCTUnwrap(edit.result)
        XCTAssertEqual(result.nutrition.calories, 500)
        XCTAssertEqual(result.nutrition.proteinG, 48, accuracy: 1e-9, "untyped values were rebased at 2 servings")
        XCTAssertEqual(try XCTUnwrap(result.nutrition.sodiumMg), 900, accuracy: 1e-9)

        edit.amountText = "1"
        XCTAssertEqual(edit.text(for: .calories), "250")
        result = try XCTUnwrap(edit.result)
        XCTAssertEqual(result.nutrition.calories, 250, accuracy: 1e-9)
        XCTAssertEqual(result.nutrition.proteinG, 24, accuracy: 1e-9)
        XCTAssertEqual(result.quantity, 1)
    }

    // MARK: - Applying

    func testApplyEditsTheEntryInPlace() throws {
        let context = ModelContext(LiftStore.makeContainer(inMemory: true))
        let loggedAt = Date(timeIntervalSince1970: 1_789_000_000)
        let entry = FoodEntry(foodRefID: "usda:170903", name: "Greek yoghurt", quantity: 150,
                              servingUnit: "g", amountGrams: 150, nutrition: facts,
                              mealType: .breakfast, loggedAt: loggedAt)
        let healthKitUUID = UUID()
        entry.healthKitUUID = healthKitUUID
        context.insert(entry)
        try context.save()
        let id = entry.id
        let dayKey = entry.dayKey

        var edit = FoodEntryEdit(entry: entry, preferredUnit: .grams)
        edit.amountText = "200"
        edit.mealType = .lunch
        XCTAssertTrue(edit.apply(to: entry))
        try context.save()

        let stored = try XCTUnwrap(try context.fetch(FetchDescriptor<FoodEntry>()).first)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<FoodEntry>()), 1, "edited, not copied")
        XCTAssertEqual(stored.id, id)
        XCTAssertEqual(stored.loggedAt, loggedAt)
        XCTAssertEqual(stored.dayKey, dayKey)
        XCTAssertEqual(stored.mealType, .lunch)
        XCTAssertEqual(stored.amountGrams, 200)
        XCTAssertEqual(stored.nutrition.calories, 400, accuracy: 1e-9)
        XCTAssertEqual(stored.healthKitUUID, healthKitUUID, "Health is not touched, so neither is its link")
    }

    func testFormatAndParseAgree() {
        XCTAssertEqual(FoodEntryEdit.format(150), "150")
        XCTAssertEqual(FoodEntryEdit.format(4.938), "4.9")
        XCTAssertEqual(FoodEntryEdit.parse(FoodEntryEdit.format(36.5)), 36.5)
        XCTAssertNil(FoodEntryEdit.parse(""))
        XCTAssertNil(FoodEntryEdit.parse("abc"))
    }
}
