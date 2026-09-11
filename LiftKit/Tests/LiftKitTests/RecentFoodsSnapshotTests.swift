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
}
