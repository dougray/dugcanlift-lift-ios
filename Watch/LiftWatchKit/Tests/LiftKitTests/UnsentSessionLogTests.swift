import XCTest
import LiftSync
@testable import LiftKit

/// A finished session must survive the app dying, the phone being in a
/// locker, and LIFT not being installed on the phone at all. These are the
/// rules that make "nothing is lost if the phone is never opened" true.
final class UnsentSessionLogTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() {
        super.setUp()
        suite = "UnsentSessionLogTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func log() -> UnsentSessionLog {
        UnsentSessionLog(defaults: defaults, maxEntries: 4)
    }

    private func session(name: String = "Upper A") -> FinishedSession {
        FinishedSession(
            name: name,
            performedOn: "2026-09-20",
            startedAt: Date(timeIntervalSince1970: 1_789_891_200),
            finishedAt: Date(timeIntervalSince1970: 1_789_894_800),
            exercises: [PerformedExercise(name: "Squat",
                                          sets: [PerformedSet(weightKg: 100, reps: 5)])]
        )
    }

    private func finished(_ id: UUID, revision: Int = 1,
                          name: String = "Upper A") -> SyncEnvelope {
        SyncEnvelope(event: .sessionFinished, workoutID: id, revision: revision,
                     updatedAt: Date(timeIntervalSince1970: 1_789_894_800),
                     origin: .watchOS, session: session(name: name))
    }

    private func ack(_ id: UUID, revision: Int = 1) -> SyncEnvelope {
        SyncEnvelope(event: .workoutSyncAck, workoutID: id, revision: revision,
                     updatedAt: Date(timeIntervalSince1970: 1_789_894_900), origin: .ios)
    }

    // MARK: - Durability

    /// The whole point: a new instance — a relaunched app — still has it.
    func testAFinishedSessionSurvivesTheAppBeingRestarted() {
        let id = UUID()
        log().record(finished(id))

        let afterRelaunch = log().pending

        XCTAssertEqual(afterRelaunch.map(\.workoutID), [id])
        XCTAssertEqual(afterRelaunch.first?.session?.exercises[0].sets[0].weightKg, 100)
    }

    /// Sending is not receiving. Only the phone's acknowledgement clears it.
    func testOnlyAnAcknowledgementRemovesASession() {
        let id = UUID()
        let sut = log()
        sut.record(finished(id))

        XCTAssertFalse(sut.acknowledge(finished(id)))       // not an ack
        XCTAssertFalse(sut.acknowledge(ack(UUID())))        // someone else's
        XCTAssertEqual(sut.pending.count, 1)

        XCTAssertTrue(sut.acknowledge(ack(id)))
        XCTAssertTrue(sut.pending.isEmpty)
    }

    /// An acknowledgement of the revision the phone actually stored does not
    /// throw away a newer edit it has never seen.
    func testAStaleAcknowledgementLeavesANewerRevisionWaiting() {
        let id = UUID()
        let sut = log()
        sut.record(finished(id, revision: 2))

        XCTAssertFalse(sut.acknowledge(ack(id, revision: 1)))
        XCTAssertEqual(sut.pending.map(\.revision), [2])

        XCTAssertTrue(sut.acknowledge(ack(id, revision: 2)))
        XCTAssertTrue(sut.pending.isEmpty)
    }

    /// One entry per session, at its newest revision: an intermediate one
    /// would be ignored on arrival anyway.
    func testANewerRevisionReplacesTheSameSessionAndAnOlderOneIsIgnored() {
        let id = UUID()
        let sut = log()
        sut.record(finished(id, revision: 2, name: "Upper A"))
        sut.record(finished(id, revision: 3, name: "Upper A (edited)"))
        sut.record(finished(id, revision: 1, name: "stale"))

        XCTAssertEqual(sut.pending.count, 1)
        XCTAssertEqual(sut.pending.first?.revision, 3)
        XCTAssertEqual(sut.pending.first?.session?.name, "Upper A (edited)")
    }

    func testOnlyFinishedSessionsAreKept() {
        let sut = log()
        sut.record(ack(UUID()))
        sut.record(SyncEnvelope(event: .workoutEdited, workoutID: UUID(), revision: 1,
                                updatedAt: Date(), origin: .watchOS))

        XCTAssertTrue(sut.pending.isEmpty)
    }

    // MARK: - Never dropped by date

    /// `StandaloneFoodLog`'s rule, for the same reason: a watch back from a
    /// flat battery believing it is 2016 must not erase what it recorded.
    /// The cap is a count, and it drops the oldest — nothing reads a clock.
    func testRetentionIsBoundedByCountOnly() {
        let sut = log()   // maxEntries: 4
        let ids = (0..<6).map { _ in UUID() }
        for id in ids { sut.record(finished(id)) }

        XCTAssertEqual(sut.pending.map(\.workoutID), Array(ids.suffix(4)))
    }

    // MARK: - Nothing here deletes what it cannot read

    /// An entry a later build wrote and this one cannot decode is carried
    /// forward rather than taken as proof the log is gone.
    func testAnUnreadableEntryIsKeptAndDoesNotCostTheReadableOnes() throws {
        let id = UUID()
        let sut = log()
        sut.record(finished(id))

        // What a build from the future might leave behind, written straight
        // into storage beside the good entry.
        let key = "com.dugcanlift.lift.unsentSessions"
        var stored = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(defaults.data(forKey: key))) as? [Any]
        )
        stored.append(["event": "SOMETHING_NEW", "workoutId": UUID().uuidString])
        defaults.set(try JSONSerialization.data(withJSONObject: stored), forKey: key)

        let reopened = log()
        XCTAssertEqual(reopened.pending.map(\.workoutID), [id])
        XCTAssertEqual(reopened.unreadableCount, 1)

        // And a write that follows does not quietly drop it.
        reopened.acknowledge(ack(id))
        XCTAssertEqual(log().unreadableCount, 1)
        XCTAssertTrue(log().pending.isEmpty)
        XCTAssertFalse(log().isEmpty)
    }
}
