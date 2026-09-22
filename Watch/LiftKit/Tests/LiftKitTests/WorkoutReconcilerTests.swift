import XCTest
@testable import LiftKit

/// docs/ARCHITECTURE.md: "a receiver inserts an unknown ID, accepts a newer
/// revision, ignores an older revision, treats an identical revision as
/// idempotent, and acknowledges the accepted revision."
final class WorkoutReconcilerTests: XCTestCase {

    private var store = WorkoutStore()

    override func setUp() {
        super.setUp()
        store = WorkoutStore()
    }

    private func snapshot(_ id: UUID, revision: Int, name: String = "Push") -> WorkoutDraft {
        WorkoutDraft(id: id, name: name, revision: revision,
                     updatedAt: Date(timeIntervalSince1970: TimeInterval(revision)))
    }

    func testInsertsUnknownIdentifier() {
        let id = UUID()
        XCTAssertEqual(store.apply(snapshot(id, revision: 3)), .inserted)
        XCTAssertEqual(store.workout(id)?.revision, 3)
    }

    func testAcceptsNewerRevision() {
        let id = UUID()
        _ = store.apply(snapshot(id, revision: 3))
        XCTAssertEqual(store.apply(snapshot(id, revision: 4, name: "Push A")), .accepted)
        XCTAssertEqual(store.workout(id)?.name, "Push A")
    }

    func testIgnoresOlderRevision() {
        let id = UUID()
        _ = store.apply(snapshot(id, revision: 4, name: "Push A"))
        XCTAssertEqual(store.apply(snapshot(id, revision: 3, name: "Push")), .ignored)
        XCTAssertEqual(store.workout(id)?.name, "Push A")
    }

    func testIdenticalRevisionIsIdempotent() {
        let id = UUID()
        _ = store.apply(snapshot(id, revision: 4, name: "Push A"))
        // A duplicate delivery carrying different content must not overwrite.
        XCTAssertEqual(store.apply(snapshot(id, revision: 4, name: "Tampered")), .idempotent)
        XCTAssertEqual(store.workout(id)?.name, "Push A")
        XCTAssertEqual(store.count, 1)
    }

    func testOutOfOrderDeliveryConvergesOnNewest() {
        let id = UUID()
        for revision in [2, 5, 3, 4, 1] {
            _ = store.apply(snapshot(id, revision: revision, name: "r\(revision)"))
        }
        XCTAssertEqual(store.workout(id)?.revision, 5)
        XCTAssertEqual(store.workout(id)?.name, "r5")
    }

    func testAcknowledgesAcceptedRevisionOnly() {
        let id = UUID()
        XCTAssertEqual(store.apply(snapshot(id, revision: 3)).acknowledgement(for: id, revision: 3, origin: .watchOS)?.revision, 3)

        let ignored = store.apply(snapshot(id, revision: 2))
        XCTAssertNil(ignored.acknowledgement(for: id, revision: 2, origin: .watchOS))
    }

    func testAcknowledgementIsAnAckEnvelope() {
        let id = UUID()
        let ack = store.apply(snapshot(id, revision: 3))
            .acknowledgement(for: id, revision: 3, origin: .watchOS)
        XCTAssertEqual(ack?.event, .workoutSyncAck)
        XCTAssertEqual(ack?.workoutID, id)
    }
}

/// The watch must stay usable with no phone in range, so edits queue locally
/// and drain in order once the transport reports it is reachable again.
final class SyncOutboxTests: XCTestCase {

    func testQueuesWhileUnreachableAndDrainsInOrder() {
        var outbox = SyncOutbox()
        // Two distinct workouts: entries for the *same* workout collapse to the
        // newest revision instead, which `testSupersedesOlderRevisions` covers.
        outbox.enqueue(.init(event: .workoutEdited, workoutID: UUID(), revision: 2,
                             updatedAt: Date(timeIntervalSince1970: 2), origin: .watchOS))
        outbox.enqueue(.init(event: .sessionFinished, workoutID: UUID(), revision: 3,
                             updatedAt: Date(timeIntervalSince1970: 3), origin: .watchOS))

        XCTAssertEqual(outbox.pending.count, 2)
        let drained = outbox.drain()
        XCTAssertEqual(drained.map(\.revision), [2, 3])
        XCTAssertTrue(outbox.pending.isEmpty)
    }

    func testSupersedesOlderRevisionsForTheSameWorkout() {
        var outbox = SyncOutbox()
        let id = UUID()
        outbox.enqueue(.init(event: .workoutEdited, workoutID: id, revision: 2,
                             updatedAt: Date(timeIntervalSince1970: 2), origin: .watchOS))
        outbox.enqueue(.init(event: .workoutEdited, workoutID: id, revision: 3,
                             updatedAt: Date(timeIntervalSince1970: 3), origin: .watchOS))

        // Only the newest edit is worth sending; the phone reconciles by revision.
        XCTAssertEqual(outbox.pending.map(\.revision), [3])
    }

    func testAcknowledgementClearsMatchingEntries() {
        var outbox = SyncOutbox()
        let id = UUID()
        outbox.enqueue(.init(event: .sessionFinished, workoutID: id, revision: 4,
                             updatedAt: Date(timeIntervalSince1970: 4), origin: .watchOS))
        outbox.acknowledge(.init(event: .workoutSyncAck, workoutID: id, revision: 4,
                                 updatedAt: Date(timeIntervalSince1970: 5), origin: .ios))
        XCTAssertTrue(outbox.pending.isEmpty)
    }

    func testStaleAcknowledgementDoesNotClearNewerEdit() {
        var outbox = SyncOutbox()
        let id = UUID()
        outbox.enqueue(.init(event: .workoutEdited, workoutID: id, revision: 6,
                             updatedAt: Date(timeIntervalSince1970: 6), origin: .watchOS))
        outbox.acknowledge(.init(event: .workoutSyncAck, workoutID: id, revision: 5,
                                 updatedAt: Date(timeIntervalSince1970: 7), origin: .ios))
        XCTAssertEqual(outbox.pending.map(\.revision), [6])
    }

    /// `.foodLogged` is a one-shot request with nothing to reconcile — the
    /// phone never sends a `WORKOUT_SYNC_ACK` for it, so `remove(workoutID:)`
    /// (not `acknowledge(_:)`) is how `WorkoutSessionModel.flushOutbox()`
    /// drops it after a successful send. This pins that removal is scoped to
    /// exactly the matching `workoutID`, leaving an unrelated food log and an
    /// unrelated workout edit queued.
    func testRemoveDropsOnlyTheMatchingFoodLogEntry() {
        var outbox = SyncOutbox()
        let firstFoodLogID = UUID()
        let secondFoodLogID = UUID()
        let workoutID = UUID()
        let foodLog = FoodLogPayload(foodRefID: "usda:1", amountGrams: 100, meal: "BREAKFAST",
                                     loggedAt: Date(timeIntervalSince1970: 8))

        outbox.enqueue(.init(event: .foodLogged, workoutID: firstFoodLogID, revision: 1,
                             updatedAt: Date(timeIntervalSince1970: 8), origin: .watchOS, foodLog: foodLog))
        outbox.enqueue(.init(event: .foodLogged, workoutID: secondFoodLogID, revision: 1,
                             updatedAt: Date(timeIntervalSince1970: 9), origin: .watchOS, foodLog: foodLog))
        outbox.enqueue(.init(event: .workoutEdited, workoutID: workoutID, revision: 3,
                             updatedAt: Date(timeIntervalSince1970: 10), origin: .watchOS))
        XCTAssertEqual(outbox.pending.count, 3)

        outbox.remove(workoutID: firstFoodLogID)

        let remainingIDs = Set(outbox.pending.map(\.workoutID))
        XCTAssertEqual(remainingIDs, [secondFoodLogID, workoutID])
        XCTAssertEqual(outbox.pending.count, 2)
        XCTAssertTrue(outbox.pending.contains { $0.workoutID == secondFoodLogID && $0.event == .foodLogged })
        XCTAssertTrue(outbox.pending.contains { $0.workoutID == workoutID && $0.event == .workoutEdited })
    }

    func testRemoveOfUnknownWorkoutIDIsANoOp() {
        var outbox = SyncOutbox()
        let id = UUID()
        outbox.enqueue(.init(event: .workoutEdited, workoutID: id, revision: 4,
                             updatedAt: Date(timeIntervalSince1970: 4), origin: .watchOS))

        outbox.remove(workoutID: UUID())

        XCTAssertEqual(outbox.pending.count, 1)
    }
}
