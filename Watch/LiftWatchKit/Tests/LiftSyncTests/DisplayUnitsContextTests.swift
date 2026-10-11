import XCTest
@testable import LiftSync

/// The phone's kg/lb and mi/km settings ride in the same application-context
/// dictionary as `RecentFoodsSnapshot`, as extra keys. These pin that the
/// keys round-trip and that the snapshot still decodes with them present,
/// so an older watch that knows nothing of units is unaffected.
final class DisplayUnitsContextTests: XCTestCase {

    private func snapshotBody() throws -> [String: Any] {
        try RecentFoodsSnapshot(
            items: [RecentFoodsSnapshot.Item(foodRefID: "usda:174608", displayName: "Chicken Breast",
                                             lastAmountGrams: 140)],
            generatedAt: Date(timeIntervalSince1970: 0)
        ).messageBody()
    }

    func testUnitsRoundTrip() throws {
        let context = DisplayUnitsContext.adding(weightUnit: "kilograms", distanceUnit: "kilometers",
                                                 to: try snapshotBody())
        XCTAssertEqual(DisplayUnitsContext.weightUnit(in: context), "kilograms")
        XCTAssertEqual(DisplayUnitsContext.distanceUnit(in: context), "kilometers")
    }

    func testSnapshotStillDecodesWithUnitsPresent() throws {
        let context = DisplayUnitsContext.adding(weightUnit: "pounds", distanceUnit: "miles",
                                                 to: try snapshotBody())
        let decoded = try RecentFoodsSnapshot(messageBody: context)
        XCTAssertEqual(decoded.items.first?.foodRefID, "usda:174608")
    }

    func testAbsentFromAnOlderPhone() throws {
        let context = try snapshotBody()
        XCTAssertNil(DisplayUnitsContext.weightUnit(in: context))
        XCTAssertNil(DisplayUnitsContext.distanceUnit(in: context))
    }
}
