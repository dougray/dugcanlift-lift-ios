import XCTest
import LiftKit

/// When the watch relays heart rate to a run the phone records, how it
/// reconnects, and when it stops. watchOS allows one live workout session, and
/// the watch's own run or lift always comes first.
final class RunHeartRateRelayPolicyTests: XCTestCase {

    func testItStartsOnlyWhenTheWatchIsFree() {
        XCTAssertTrue(RunHeartRateRelayPolicy.shouldStart(watchBusy: false, relaying: false))
        XCTAssertFalse(RunHeartRateRelayPolicy.shouldStart(watchBusy: true, relaying: false),
                       "the watch's own run or lift is never ended for the phone's")
        XCTAssertFalse(RunHeartRateRelayPolicy.shouldStart(watchBusy: false, relaying: true),
                       "a second request while relaying starts nothing new")
    }

    func testAPhoneUnreachableWhenItJustAskedEndsTheRelay() {
        XCTAssertTrue(RunHeartRateRelayPolicy.afterFirstMirroring(succeeded: true))
        XCTAssertFalse(RunHeartRateRelayPolicy.afterFirstMirroring(succeeded: false))
    }

    /// A dropped phone is tried again after 2, 5 and 10 seconds; the fourth
    /// failure ends the relay.
    func testAReconnectWaitsLongerEachTimeThenEnds() {
        var reconnect = RunHeartRateRelayPolicy.Reconnect()
        XCTAssertEqual(reconnect.disconnected(), .mirrorAgain(after: 2))
        XCTAssertTrue(reconnect.reconnecting)
        XCTAssertEqual(reconnect.tryFailed(), .mirrorAgain(after: 5))
        XCTAssertEqual(reconnect.tryFailed(), .mirrorAgain(after: 10))
        XCTAssertEqual(reconnect.tryFailed(), .end,
                       "a phone that is gone must not leave a workout running on the wrist")
    }

    /// A mirroring call that returns is not the phone listening: only a
    /// reading that gets through starts the count over.
    func testOnlyADeliveredReadingStartsTheCountOver() {
        var reconnect = RunHeartRateRelayPolicy.Reconnect()
        XCTAssertEqual(reconnect.disconnected(), .mirrorAgain(after: 2))
        XCTAssertEqual(reconnect.tryFailed(), .mirrorAgain(after: 5))
        reconnect.trySucceeded()
        XCTAssertFalse(reconnect.reconnecting)
        // It drops again before any reading got through: the count carries on.
        XCTAssertEqual(reconnect.disconnected(), .mirrorAgain(after: 5))
        reconnect.trySucceeded()
        reconnect.readingDelivered()
        XCTAssertEqual(reconnect.failedTries, 0)
        XCTAssertEqual(reconnect.disconnected(), .mirrorAgain(after: 2), "a fresh drop waits the shortest again")
    }

    func testFiveUnheardMinutesEndTheRelay() {
        let heard = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(RunHeartRateRelayPolicy.unheardLimit, 300)
        XCTAssertFalse(RunHeartRateRelayPolicy.isUnheardTooLong(lastHeard: heard, now: heard.addingTimeInterval(299)))
        XCTAssertTrue(RunHeartRateRelayPolicy.isUnheardTooLong(lastHeard: heard, now: heard.addingTimeInterval(300)))
        XCTAssertGreaterThan(RunHeartRateRelayPolicy.unheardLimit,
                             RunHeartRateRelayPolicy.reconnectDelays.reduce(0, +),
                             "the backstop never cuts a reconnect short")
    }

    /// The watch measures heart rate and nothing else for the phone's run.
    func testOnlyHeartRateIsCollected() {
        XCTAssertEqual(RunHeartRateRelayPolicy.collectedTypeIdentifiers,
                       ["HKQuantityTypeIdentifierHeartRate"])
    }
}
