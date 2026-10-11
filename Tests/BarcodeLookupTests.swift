import XCTest
import SwiftData
import LiftCore
@testable import Lift

@MainActor
final class BarcodeLookupTests: XCTestCase {
    private func makeContext() -> ModelContext { ModelContext(LiftStore.makeContainer(inMemory: true)) }
    private let flakes = NutritionFacts(calories: 357, proteinG: 7, carbsG: 84, fatG: 0.4)

    func testAnUnknownValidCodeIsUnknown() {
        let context = makeContext()
        XCTAssertEqual(BarcodeLookup.look(up: "036000291452", symbology: nil, in: context),
                       .unknown(try! Barcode.read("036000291452").get()))
    }

    func testABadCheckDigitIsNeverLookedUp() {
        let context = makeContext()
        RememberedFoods.remember(code: "36000291453", name: "Should never match", per100g: flakes, in: context)
        XCTAssertEqual(BarcodeLookup.look(up: "036000291453", symbology: nil, in: context), .didNotScanCleanly)
    }

    func testARememberedCodeIsFoundFromEverySpelling() throws {
        let context = makeContext()
        RememberedFoods.remember(code: "36000291452", name: "Corn flakes", per100g: flakes, in: context)
        for raw in ["036000291452", "0036000291452", "00036000291452"] {
            guard case .remembered(let food) = BarcodeLookup.look(up: raw, symbology: nil, in: context) else {
                return XCTFail(raw)
            }
            XCTAssertEqual(food.name, "Corn flakes")
            XCTAssertEqual(food.id, "barcode:36000291452")
            XCTAssertEqual(food.rememberedCode, "36000291452")
        }
    }

    func testRememberingAgainUpdatesInPlaceAndKeepsTheFirstDate() throws {
        let context = makeContext()
        let first = Date(timeIntervalSince1970: 1_000)
        let later = Date(timeIntervalSince1970: 2_000)
        RememberedFoods.remember(code: "36000291452", name: "Corn flakes", per100g: flakes, in: context, now: first)
        RememberedFoods.remember(code: "36000291452", name: "Frosted flakes", per100g: flakes, in: context, now: later)
        let all = try context.fetch(FetchDescriptor<RememberedFood>())
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.name, "Frosted flakes")
        XCTAssertEqual(all.first?.rememberedAt, first)
        XCTAssertEqual(all.first?.updatedAt, later)
    }

    func testForgetRemovesItAndTheCodeIsUnknownAgain() {
        let context = makeContext()
        RememberedFoods.remember(code: "36000291452", name: "Corn flakes", per100g: flakes, in: context)
        RememberedFoods.forget(code: "36000291452", in: context)
        XCTAssertNil(RememberedFoods.find(code: "36000291452", in: context))
        if case .remembered = BarcodeLookup.look(up: "036000291452", symbology: nil, in: context) { XCTFail() }
    }

    func testALoggableFoodScalesPer100g() {
        let food = LoggableFood(remembered: RememberedFood(code: "1", name: "x", per100g: flakes))
        XCTAssertEqual(food.nutrition(grams: 30).calories, 107.1, accuracy: 0.001)
        XCTAssertNil(food.nutrition(grams: 30).fiberG, "blank stays blank")
        XCTAssertEqual(LoggableFood.rememberedLine, "A food you entered.")
    }
}
