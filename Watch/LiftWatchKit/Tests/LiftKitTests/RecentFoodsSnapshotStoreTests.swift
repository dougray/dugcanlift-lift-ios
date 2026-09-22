import XCTest
@testable import LiftKit

final class RecentFoodsSnapshotStoreTests: XCTestCase {
    private var defaults: UserDefaults!

    private let suiteName = "RecentFoodsSnapshotStoreTests"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testCachedIsNilWhenNothingSaved() {
        let store = RecentFoodsSnapshotStore(defaults: defaults)
        XCTAssertNil(store.cached)
    }

    func testSaveThenCachedRoundTrips() {
        let store = RecentFoodsSnapshotStore(defaults: defaults)
        let snapshot = RecentFoodsSnapshot(
            items: [RecentFoodsSnapshot.Item(foodRefID: "usda:1", displayName: "Apple", lastAmountGrams: 182)],
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        store.save(snapshot)
        XCTAssertEqual(store.cached, snapshot)
    }

    func testSaveOverwritesPreviousSnapshot() {
        let store = RecentFoodsSnapshotStore(defaults: defaults)
        store.save(RecentFoodsSnapshot(items: [], generatedAt: Date(timeIntervalSince1970: 1)))
        let newer = RecentFoodsSnapshot(
            items: [RecentFoodsSnapshot.Item(foodRefID: "usda:2", displayName: "Banana", lastAmountGrams: nil)],
            generatedAt: Date(timeIntervalSince1970: 2)
        )
        store.save(newer)
        XCTAssertEqual(store.cached, newer)
    }

    func testCorruptedDataReturnsNilRatherThanCrashing() {
        defaults.set(Data("not json".utf8), forKey: "com.dugcanlift.lift.recentFoodsSnapshot")
        let store = RecentFoodsSnapshotStore(defaults: defaults)
        XCTAssertNil(store.cached)
    }
}
