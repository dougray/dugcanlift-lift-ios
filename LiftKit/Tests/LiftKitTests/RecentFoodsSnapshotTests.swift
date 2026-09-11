import XCTest
@testable import LiftKit

/// `shared/contracts/recent-foods-snapshot.schema.json` is the wire contract
/// with the phone. These tests pin the encoding to that schema's field names
/// and its `date-time` format for `generatedAt`, the same way
/// `SyncEnvelopeTests` pins `SyncEnvelope`.
final class RecentFoodsSnapshotTests: XCTestCase {

    private func json(_ snapshot: RecentFoodsSnapshot) throws -> [String: Any] {
        let data = try SyncEnvelope.encoder.encode(snapshot)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testEncodesContractFieldNames() throws {
        let snapshot = RecentFoodsSnapshot(
            items: [
                RecentFoodsSnapshot.Item(foodRefID: "usda:174608", displayName: "Chicken Breast", lastAmountGrams: 140),
                RecentFoodsSnapshot.Item(foodRefID: "recipe:6A2A8B6E-3D2F-4E77-9B4E-2C6A5E8C1D01", displayName: "Overnight Oats", lastAmountGrams: nil)
            ],
            generatedAt: Date(timeIntervalSince1970: 0)
        )
        let object = try json(snapshot)

        XCTAssertEqual(object["generatedAt"] as? String, "1970-01-01T00:00:00Z")
        let items = try XCTUnwrap(object["items"] as? [[String: Any]])
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0]["foodRefID"] as? String, "usda:174608")
        XCTAssertEqual(items[0]["displayName"] as? String, "Chicken Breast")
        XCTAssertEqual(items[0]["lastAmountGrams"] as? Double, 140)
        XCTAssertNil(items[1]["lastAmountGrams"])
    }

    func testRoundTrips() throws {
        let snapshot = RecentFoodsSnapshot(
            items: [RecentFoodsSnapshot.Item(foodRefID: "usda:1", displayName: "Apple", lastAmountGrams: 182)],
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let data = try SyncEnvelope.encoder.encode(snapshot)
        let decoded = try SyncEnvelope.decoder.decode(RecentFoodsSnapshot.self, from: data)
        XCTAssertEqual(decoded, snapshot)
    }

    func testInitFromApplicationContextDecodesRealPayload() throws {
        let context: [String: Any] = [
            "items": [
                ["foodRefID": "off:12345", "displayName": "Greek Yogurt", "lastAmountGrams": 170.0]
            ],
            "generatedAt": "2026-09-10T08:00:00Z"
        ]
        let snapshot = try RecentFoodsSnapshot(applicationContext: context)
        XCTAssertEqual(snapshot.items.count, 1)
        XCTAssertEqual(snapshot.items[0].foodRefID, "off:12345")
        XCTAssertEqual(snapshot.items[0].lastAmountGrams, 170.0)
        XCTAssertEqual(snapshot.generatedAt, Date(timeIntervalSince1970: 1_789_027_200))
    }

    func testEmptyItemsListDecodes() throws {
        let context: [String: Any] = ["items": [], "generatedAt": "2026-09-10T08:00:00Z"]
        let snapshot = try RecentFoodsSnapshot(applicationContext: context)
        XCTAssertTrue(snapshot.items.isEmpty)
    }

    func testItemsWithSameFoodRefIDButDifferentNameAreDistinctForHashing() throws {
        // The phone's recent-foods query dedups by displayName, not
        // foodRefID, and legacy entries can share an empty-string
        // foodRefID — so `RecentFoodsListView` uses `id: \.self` rather than
        // `id: \.foodRefID`. That's only safe if two items sharing a
        // foodRefID still hash/compare as different when their other fields
        // differ, which is what this test pins.
        let first = RecentFoodsSnapshot.Item(foodRefID: "", displayName: "Homemade Soup", lastAmountGrams: 250)
        let second = RecentFoodsSnapshot.Item(foodRefID: "", displayName: "Leftover Pasta", lastAmountGrams: 300)

        XCTAssertNotEqual(first, second)
        // A `Set` relies on `Hashable` (not just `Equatable`) to tell the two
        // apart; if they collapsed to one entry, `List(items, id: \.self)`
        // would drop a row the same way `id: \.foodRefID` did.
        XCTAssertEqual(Set([first, second]).count, 2)
    }

    func testUnknownFieldsAreTolerated() throws {
        // The schema sets additionalProperties: true.
        let context: [String: Any] = [
            "items": [["foodRefID": "usda:1", "displayName": "Apple", "lastAmountGrams": NSNull(), "extra": true]],
            "generatedAt": "2026-09-10T08:00:00Z",
            "extra": true
        ]
        let snapshot = try RecentFoodsSnapshot(applicationContext: context)
        XCTAssertNil(snapshot.items[0].lastAmountGrams)
    }

    func testItemDecodesWithoutMacrosForBackwardCompatibility() throws {
        // A snapshot cached before this change has no macros. It must still
        // decode — the user's recents list keeps working — with macros nil.
        let json = """
        {"generatedAt":"1970-01-01T00:00:00Z","items":[{"foodRefID":"usda:1","displayName":"Oats","lastAmountGrams":50}]}
        """.data(using: .utf8)!
        let snapshot = try SyncEnvelope.decoder.decode(RecentFoodsSnapshot.self, from: json)
        XCTAssertNil(snapshot.items[0].nutritionPer100g)
        XCTAssertNil(snapshot.items[0].watchFood)
    }

    func testWatchFoodUsesTheItemsOwnDisplayName() {
        // The phone sends the reference food's macros, but the display name
        // the user recognises is the item's. Exporting the reference name
        // would show them a food they never chose.
        let macros = WatchFood(name: "ignored", kcal: 379, protein: 13.2,
                               fat: 6.5, carbs: 67.7, fibre: 10.1)
        let item = RecentFoodsSnapshot.Item(foodRefID: "usda:1", displayName: "Porridge",
                                            lastAmountGrams: 50, nutritionPer100g: macros)
        XCTAssertEqual(item.watchFood?.name, "Porridge")
        XCTAssertEqual(item.watchFood?.kcal, 379)
    }

    func testMacrosSurviveAFullEncodeDecodeRoundTrip() throws {
        // Encode and decode together, through the real coders, with macros
        // present. The other tests either build an Item directly or decode a
        // hand-written literal, so neither would notice if the Swift property
        // names drifted away from the names
        // `shared/contracts/recent-foods-snapshot.schema.json` pins — the
        // encoder and the literal would simply drift together. This is the
        // test that fails when that happens.
        let macros = WatchFood(name: "Oats, rolled, dry", kcal: 379, protein: 13.2,
                               fat: 6.5, carbs: 67.7, fibre: 10.1)
        let original = RecentFoodsSnapshot(
            items: [RecentFoodsSnapshot.Item(foodRefID: "usda:1", displayName: "Porridge",
                                             lastAmountGrams: 50, nutritionPer100g: macros)],
            generatedAt: Date(timeIntervalSince1970: 1_757_500_800)
        )

        let data = try SyncEnvelope.encoder.encode(original)
        let decoded = try SyncEnvelope.decoder.decode(RecentFoodsSnapshot.self, from: data)
        XCTAssertEqual(decoded, original)

        // And the wire keys themselves, since equality would still hold if
        // both sides renamed a field in step.
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        let item = try XCTUnwrap((object["items"] as? [[String: Any]])?.first)
        let nutrition = try XCTUnwrap(item["nutritionPer100g"] as? [String: Any])
        XCTAssertEqual(Set(nutrition.keys),
                       ["name", "kcal", "protein", "fat", "carbs", "fibre"])
    }
}
