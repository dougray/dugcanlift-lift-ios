import XCTest
@testable import LiftKit

/// Mirrors `WorkoutReconcilerTests`: a receiver inserts an unknown ID, accepts
/// a newer revision, ignores an older revision, and treats an identical
/// revision as idempotent (docs/ARCHITECTURE.md).
final class OutdoorActivityStoreTests: XCTestCase {

    private var store = OutdoorActivityStore()

    override func setUp() {
        super.setUp()
        store = OutdoorActivityStore()
    }

    private func snapshot(_ id: UUID, revision: Int, distanceMeters: Double = 0) -> OutdoorActivity {
        OutdoorActivity(
            id: id,
            activityType: .run,
            startedAt: Date(timeIntervalSince1970: 0),
            distanceMeters: distanceMeters,
            revision: revision,
            updatedAt: Date(timeIntervalSince1970: TimeInterval(revision))
        )
    }

    func testInsertsUnknownIdentifier() {
        let id = UUID()
        XCTAssertEqual(store.apply(snapshot(id, revision: 3)), .inserted)
        XCTAssertEqual(store.activity(id)?.revision, 3)
    }

    func testAcceptsNewerRevision() {
        let id = UUID()
        _ = store.apply(snapshot(id, revision: 3))
        XCTAssertEqual(store.apply(snapshot(id, revision: 4, distanceMeters: 500)), .accepted)
        XCTAssertEqual(store.activity(id)?.distanceMeters, 500)
    }

    func testIgnoresOlderRevision() {
        let id = UUID()
        _ = store.apply(snapshot(id, revision: 4, distanceMeters: 500))
        XCTAssertEqual(store.apply(snapshot(id, revision: 3, distanceMeters: 100)), .ignored)
        XCTAssertEqual(store.activity(id)?.distanceMeters, 500)
    }

    func testIdenticalRevisionIsIdempotent() {
        let id = UUID()
        _ = store.apply(snapshot(id, revision: 4, distanceMeters: 500))
        // A duplicate delivery carrying different content must not overwrite.
        XCTAssertEqual(store.apply(snapshot(id, revision: 4, distanceMeters: 999)), .idempotent)
        XCTAssertEqual(store.activity(id)?.distanceMeters, 500)
        XCTAssertEqual(store.count, 1)
    }

    func testOutOfOrderDeliveryConvergesOnNewest() {
        let id = UUID()
        for revision in [2, 5, 3, 4, 1] {
            _ = store.apply(snapshot(id, revision: revision, distanceMeters: Double(revision)))
        }
        XCTAssertEqual(store.activity(id)?.revision, 5)
        XCTAssertEqual(store.activity(id)?.distanceMeters, 5)
    }

    func testStoreBypassesReconciliation() {
        let id = UUID()
        _ = store.apply(snapshot(id, revision: 5, distanceMeters: 500))
        // A local edit overwrites regardless of revision — this device is the author.
        store.store(snapshot(id, revision: 1, distanceMeters: 10))
        XCTAssertEqual(store.activity(id)?.revision, 1)
        XCTAssertEqual(store.activity(id)?.distanceMeters, 10)
    }

    func testRemoveDeletesTheActivity() {
        let id = UUID()
        _ = store.apply(snapshot(id, revision: 1))
        store.remove(id)
        XCTAssertNil(store.activity(id))
        XCTAssertEqual(store.count, 0)
    }
}
