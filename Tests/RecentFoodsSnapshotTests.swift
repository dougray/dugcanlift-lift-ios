import XCTest
@testable import Lift

/// `dugcanlift-watch/shared/contracts/recent-foods-snapshot.schema.json`
/// is the wire contract shared with watchOS. These tests pin the encoding
/// to that schema, same as `SyncEnvelopeTests` does for `SyncEnvelope`.
final class RecentFoodsSnapshotTests: XCTestCase {

    private func json(_ snapshot: RecentFoodsSnapshot) throws -> [String: Any] {
        let data = try SyncEnvelope.encoder.encode(snapshot)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testRoundTrips() throws {
        let snapshot = RecentFoodsSnapshot(
            items: [
                RecentFoodsSnapshot.Item(foodRefID: "usda:174608", displayName: "Chicken breast, roll, oven-roasted", lastAmountGrams: 150),
                RecentFoodsSnapshot.Item(foodRefID: "off:3017620422003", displayName: "Nutella", lastAmountGrams: nil)
            ],
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let data = try SyncEnvelope.encoder.encode(snapshot)
        let decoded = try SyncEnvelope.decoder.decode(RecentFoodsSnapshot.self, from: data)

        XCTAssertEqual(decoded, snapshot)
        XCTAssertEqual(decoded.generatedAt, snapshot.generatedAt)
        XCTAssertEqual(decoded.items, snapshot.items)
    }

    func testMessageBodyRoundTripsThroughSyncEnvelopeStyleCoding() throws {
        let snapshot = RecentFoodsSnapshot(
            items: [RecentFoodsSnapshot.Item(foodRefID: "usda:174608", displayName: "Chicken breast, roll, oven-roasted", lastAmountGrams: 150)],
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let body = try snapshot.messageBody()

        let decoded = try RecentFoodsSnapshot(messageBody: body)

        XCTAssertEqual(decoded, snapshot)
    }

    func testEncodesGeneratedAtAsISO8601NotNumericTimestamp() throws {
        // The exact bug already caught once for SyncEnvelope: a bare
        // JSONEncoder() has no .iso8601 date strategy and would encode
        // `generatedAt` as a numeric timeIntervalSinceReferenceDate instead
        // of the ISO-8601 date-time string the rest of this contract uses.
        let snapshot = RecentFoodsSnapshot(items: [], generatedAt: Date(timeIntervalSince1970: 0))
        let object = try json(snapshot)

        XCTAssertEqual(object["generatedAt"] as? String, "1970-01-01T00:00:00Z")
    }

    func testEncodesContractFieldNames() throws {
        let snapshot = RecentFoodsSnapshot(
            items: [RecentFoodsSnapshot.Item(foodRefID: "usda:174608", displayName: "Chicken breast", lastAmountGrams: 150)],
            generatedAt: Date(timeIntervalSince1970: 0)
        )
        let object = try json(snapshot)

        XCTAssertEqual(Set(object.keys), ["items", "generatedAt"])
        let items = try XCTUnwrap(object["items"] as? [[String: Any]])
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(Set(items[0].keys), ["foodRefID", "displayName", "lastAmountGrams"])
    }

    func testEmptyItemsRoundTrips() throws {
        let snapshot = RecentFoodsSnapshot(items: [], generatedAt: .now)
        let data = try SyncEnvelope.encoder.encode(snapshot)
        let decoded = try SyncEnvelope.decoder.decode(RecentFoodsSnapshot.self, from: data)
        XCTAssertTrue(decoded.items.isEmpty)
    }
}
