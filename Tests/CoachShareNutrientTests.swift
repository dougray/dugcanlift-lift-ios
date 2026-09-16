import XCTest
import SwiftData
import LiftCore
@testable import Lift

/// Saturated fat, sugar and sodium in a Send to Coach link — SHARE-FORMAT.md
/// "Saturated fat, sugar and sodium": `fx` on a day, `fe` beside itemised `f`.
///
/// What is summed, counted and rounded is `LiftCore.ShareNutrients`', which the
/// kit pins against LIFT Android's rules. These tests pin what this encoder
/// feeds it: every food of the day, at servings 1 because `FoodEntry.nutrition`
/// is already what was eaten, and `fe` in `f`'s order.
final class CoachShareNutrientTests: XCTestCase {

    private func makeContext() -> ModelContext {
        ModelContext(LiftStore.makeContainer(inMemory: true))
    }

    private func food(_ name: String, _ context: ModelContext, at date: Date = .now,
                      saturatedFat: Double? = nil, sugar: Double? = nil, sodium: Double? = nil) -> FoodEntry {
        let entry = FoodEntry(foodRefID: "usda:\(name)", name: name, quantity: 1, servingUnit: "serving",
                              nutrition: NutritionFacts(calories: 100, proteinG: 5, carbsG: 10, fatG: 3,
                                                        sugarG: sugar, sodiumMg: sodium, saturatedFatG: saturatedFat),
                              mealType: .lunch, loggedAt: date)
        context.insert(entry)
        return entry
    }

    private func payloadDays(_ foods: [FoodEntry], itemised: Bool) -> [[String: Any]] {
        let snapshot = CoachShare.Snapshot(days: [], food: foods, measurements: [], goal: nil, unit: .pounds)
        let payload = CoachShare.buildPayload(from: snapshot, weeks: 1, itemised: itemised, lastRoute: false)
        return payload["d"] as? [[String: Any]] ?? []
    }

    /// Bytes, not NSNumber equality, which would let 1 equal true.
    private func json(_ value: Any?) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: try XCTUnwrap(value), options: [.sortedKeys, .fragmentsAllowed])
        return String(decoding: data, as: UTF8.self)
    }

    private func mixedDay(_ context: ModelContext) -> [FoodEntry] {
        [
            food("soup", context, saturatedFat: 2.44, sugar: 5, sodium: 890.4),
            food("oats", context),
            food("cola", context, sugar: 39),
            food("crisps", context, saturatedFat: 1.12, sodium: 420.2),
        ]
    }

    func testFxTotalsOnlyTheFoodsThatRecordedEachAndSaysHowMany() throws {
        let context = makeContext()
        let day = try XCTUnwrap(payloadDays(mixedDay(context), itemised: false).first)
        // 2.44 + 1.12 = 3.56 -> 3.6; 5 + 39 = 44; 890.4 + 420.2 = 1310.6 -> 1311.
        XCTAssertEqual(try json(day["fx"]), "[3.6,44,1311,4,2,2,2]")
        XCTAssertNotNil(day["ft"], "fx sits beside the totals, it does not replace them")
        XCTAssertNil(day["fe"], "fe only goes with an itemised f")
    }

    func testAnItemisedDayCarriesFeInFsOrderAndStillSendsFx() throws {
        let context = makeContext()
        let foods = mixedDay(context)
        let day = try XCTUnwrap(payloadDays(foods, itemised: true).first)

        let f = try XCTUnwrap(day["f"] as? [[Any]])
        let fe = try XCTUnwrap(day["fe"] as? [Any])
        XCTAssertEqual(fe.count, f.count, "one fe entry per f entry")
        XCTAssertEqual(try json(fe), "[[2.4,5,890],null,[null,39],[1.1,null,420]]",
                       "rounded per entry, trailing nulls trimmed, null for a food with none")
        XCTAssertEqual(try json(day["fx"]), "[3.6,44,1311,4,2,2,2]",
                       "summed unrounded, so a coach never has to add fe up")
    }

    func testNoFoodRecordingAnyMeansNoKeysAtAll() throws {
        let context = makeContext()
        let foods = [food("oats", context), food("rice", context)]
        for itemised in [true, false] {
            let day = try XCTUnwrap(payloadDays(foods, itemised: itemised).first)
            XCTAssertNil(day["fx"])
            XCTAssertNil(day["fe"])
        }
    }

    func testATotalNoFoodRecordedIsNullNotZero() throws {
        let context = makeContext()
        let day = try XCTUnwrap(payloadDays([food("cola", context, sugar: 39)], itemised: false).first)
        XCTAssertEqual(try json(day["fx"]), "[null,39,null,1,0,1,0]")
    }

    /// `FoodEntry.nutrition` is already scaled to what was eaten, and `f` sends
    /// servings 1, so the stored values go as they are rather than multiplied
    /// again by the logged quantity.
    func testAGramEntrysStoredTotalsAreNotMultipliedAgain() throws {
        let context = makeContext()
        let banana = FoodEntry(foodRefID: "usda:173944", name: "Bananas, raw", quantity: 120, servingUnit: "g",
                               amountGrams: 120,
                               nutrition: NutritionFacts(calories: 106.8, sugarG: 14.676, sodiumMg: 1.2,
                                                         saturatedFatG: 0.1344),
                               mealType: .snack)
        context.insert(banana)
        let day = try XCTUnwrap(payloadDays([banana], itemised: true).first)
        XCTAssertEqual(try json(day["fe"]), "[[0.1,14.7,1]]")
        XCTAssertEqual(try json(day["fx"]), "[0.1,14.7,1,1,1,1,1]")
    }

    func testEachDayGetsItsOwnFx() throws {
        let context = makeContext()
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: .now)!
        let foods = [food("soup", context, sodium: 500), food("cola", context, at: yesterday, sugar: 39)]
        let days = payloadDays(foods, itemised: false)
        XCTAssertEqual(days.count, 2)
        let fx = try days.map { try json($0["fx"]) }
        XCTAssertEqual(Set(fx), ["[null,null,500,1,0,0,1]", "[null,39,null,1,0,1,0]"])
    }

    /// The whole link, decoded by the kit's own reader — the one Coach iOS
    /// uses — so the keys, the tuple shapes and fe's alignment with f are
    /// checked by something other than this encoder.
    func testTheLinkDecodesWithTheKitsReader() throws {
        let context = makeContext()
        let snapshot = CoachShare.Snapshot(days: [], food: mixedDay(context), measurements: [], goal: nil, unit: .pounds)
        let link = try CoachShare.buildLink(from: snapshot, weeks: 1, itemised: true, lastRoute: false)
        let fragment = try XCTUnwrap(link.split(separator: "#").last.map(String.init))
        let day = try XCTUnwrap(try ShareLinkCodec.decode(fragment: fragment).d.first)

        let fx = try XCTUnwrap(day.fx)
        XCTAssertEqual(fx.saturatedFatG, 3.6)
        XCTAssertEqual(fx.sugarG, 44)
        XCTAssertEqual(fx.sodiumMg, 1311)
        XCTAssertEqual([fx.foods, fx.withSaturatedFat, fx.withSugar, fx.withSodium], [4, 2, 2, 2])

        let fe = try XCTUnwrap(day.fe, "kept only when its length matches f")
        XCTAssertEqual(fe.count, day.f?.count)
        XCTAssertEqual(fe[0], WireNutrientDetails(saturatedFatG: 2.4, sugarG: 5, sodiumMg: 890))
        XCTAssertNil(fe[1])
        XCTAssertEqual(fe[2], WireNutrientDetails(sugarG: 39))
    }

    /// A rounded 14.7 goes out as "14.7", as LIFT web and Android write it,
    /// not the seventeen digits JSONSerialization gives a Double.
    func testRoundedValuesAreWrittenShort() throws {
        XCTAssertEqual(try json(CoachShare.shortDecimals([14.699999999999999, 890.0, NSNull()])), "[14.7,890,null]")
    }
}
