import XCTest
import SwiftData
import LiftCore
@testable import Lift

/// A remembered food is the person's own library, kept on this phone. A food
/// logged from one is an ordinary entry once it is logged, and the share
/// carries it like any other: by name and nutrition, never by the barcode it
/// was found under.
@MainActor
final class CoachShareRememberedFoodTests: XCTestCase {
    func testASharedLogCarriesNoBarcodeAndNoRememberedFood() throws {
        let context = ModelContext(LiftStore.makeContainer(inMemory: true))
        RememberedFoods.remember(code: "36000291452", name: "Corn flakes",
                                 per100g: NutritionFacts(calories: 357, proteinG: 7, carbsG: 84, fatG: 0.4), in: context)
        let entry = FoodEntry(foodRefID: "barcode:36000291452", name: "Corn flakes", brand: nil,
                              quantity: 30, servingUnit: "g", amountGrams: 30,
                              nutrition: NutritionFacts(calories: 107, proteinG: 2, carbsG: 25, fatG: 0.1),
                              mealType: .breakfast)
        context.insert(entry)
        let snapshot = CoachShare.Snapshot(days: [], food: [entry], measurements: [], goal: nil, unit: .pounds)
        let payload = CoachShare.buildPayload(from: snapshot, weeks: 1, itemised: true, lastRoute: false)
        let json = String(decoding: try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]), as: UTF8.self)
        XCTAssertFalse(json.contains("36000291452"), "the barcode never travels to a coach")
        XCTAssertFalse(json.contains("remembered"))
        XCTAssertFalse(json.contains("barcode"))
        XCTAssertTrue(json.contains("Corn flakes"), "the food itself is shared like any other entry")
    }
}
