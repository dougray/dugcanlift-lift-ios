import XCTest
@testable import LiftKit
import LiftSync

/// The outbox hands each revision to `transferUserInfo` once. It used to
/// hand every pending envelope over again on every flush, and the phone
/// acknowledges nothing but foods, so a finished session was queued again
/// with every later set, food and reachability change.
final class SyncOutboxHandoverTests: XCTestCase {

    private let workout = UUID()
    private let run = UUID()

    private func envelope(_ event: SyncEnvelope.Event, _ id: UUID, revision: Int) -> SyncEnvelope {
        SyncEnvelope(event: event, workoutID: id, revision: revision,
                     updatedAt: Date(timeIntervalSince1970: 1_758_400_000), origin: .watchOS)
    }

    private func flush(_ outbox: inout SyncOutbox) -> [SyncEnvelope] {
        let handed = outbox.unsent
        for envelope in handed { outbox.markHandedOver(envelope) }
        return handed
    }

    func testARevisionIsHandedOverOnceAndStaysPending() {
        var outbox = SyncOutbox()
        outbox.enqueue(envelope(.workoutEdited, workout, revision: 1))

        XCTAssertEqual(flush(&outbox).count, 1)
        XCTAssertEqual(flush(&outbox).count, 0)
        // Still pending: only an acknowledgement clears it.
        XCTAssertEqual(outbox.pending.count, 1)
    }

    func testANewerRevisionIsHandedOver() {
        var outbox = SyncOutbox()
        outbox.enqueue(envelope(.workoutEdited, workout, revision: 1))
        _ = flush(&outbox)
        outbox.enqueue(envelope(.workoutEdited, workout, revision: 2))
        XCTAssertEqual(flush(&outbox).map(\.revision), [2])
    }

    /// Finishing edits the workout (WORKOUT_EDITED) and then queues
    /// SESSION_FINISHED at that same revision. The second is new news.
    func testADifferentEventAtTheSameRevisionIsHandedOver() {
        var outbox = SyncOutbox()
        outbox.enqueue(envelope(.workoutEdited, workout, revision: 5))
        _ = flush(&outbox)
        outbox.enqueue(envelope(.sessionFinished, workout, revision: 5))
        XCTAssertEqual(flush(&outbox).map(\.event), [.sessionFinished])
        XCTAssertEqual(flush(&outbox), [])
    }

    /// A later flush for something else leaves what was already handed over
    /// alone: the case that used to requeue a finished run with every set.
    func testAnotherWorkoutsFlushDoesNotRepeatThisOne() {
        var outbox = SyncOutbox()
        outbox.enqueue(envelope(.outdoorActivityFinished, run, revision: 2))
        _ = flush(&outbox)
        outbox.enqueue(envelope(.workoutEdited, workout, revision: 1))
        XCTAssertEqual(flush(&outbox).map(\.workoutID), [workout])
    }

    func testAFailedHandoverIsHandedOverAgain() {
        var outbox = SyncOutbox()
        let finished = envelope(.sessionFinished, workout, revision: 3)
        outbox.enqueue(finished)
        _ = flush(&outbox)

        outbox.handoverFailed(finished)
        XCTAssertEqual(flush(&outbox), [finished])
    }

    /// A failure reported for an older revision must not make the newer one
    /// look unsent a second time, or be lost.
    func testAStaleFailureChangesNothing() {
        var outbox = SyncOutbox()
        let older = envelope(.workoutEdited, workout, revision: 1)
        outbox.enqueue(older)
        _ = flush(&outbox)
        outbox.enqueue(envelope(.workoutEdited, workout, revision: 2))
        _ = flush(&outbox)

        outbox.handoverFailed(older)
        XCTAssertEqual(flush(&outbox), [])
        XCTAssertEqual(outbox.pending.map(\.revision), [2])
    }

    func testAnAcknowledgementClearsItAndItsHandover() {
        var outbox = SyncOutbox()
        outbox.enqueue(envelope(.workoutEdited, workout, revision: 4))
        _ = flush(&outbox)
        outbox.acknowledge(envelope(.workoutSyncAck, workout, revision: 4))
        XCTAssertTrue(outbox.isEmpty)

        // The same id coming back at a new revision is handed over afresh.
        outbox.enqueue(envelope(.workoutEdited, workout, revision: 5))
        XCTAssertEqual(flush(&outbox).map(\.revision), [5])
    }
}
