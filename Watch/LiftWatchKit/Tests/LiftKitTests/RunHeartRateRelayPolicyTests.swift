import XCTest
import LiftKit

/// When the watch relays heart rate to a run the phone records, and when it
/// stops. watchOS allows one live workout session, and the watch's own run or
/// lift always comes first.
final class RunHeartRateRelayPolicyTests: XCTestCase {

    func testItStartsOnlyWhenTheWatchIsFree() {
        XCTAssertTrue(RunHeartRateRelayPolicy.shouldStart(watchBusy: false, relaying: false))
        XCTAssertFalse(RunHeartRateRelayPolicy.shouldStart(watchBusy: true, relaying: false),
                       "the watch's own run or lift is never ended for the phone's")
        XCTAssertFalse(RunHeartRateRelayPolicy.shouldStart(watchBusy: false, relaying: true),
                       "a second request while relaying starts nothing new")
    }

    func testALostPhoneIsAskedAgainAFewTimesThenTheRelayEnds() {
        XCTAssertEqual(RunHeartRateRelayPolicy.afterDisconnect(retriesSoFar: 0), .mirrorAgain)
        XCTAssertEqual(RunHeartRateRelayPolicy.afterDisconnect(retriesSoFar: 2), .mirrorAgain)
        XCTAssertEqual(RunHeartRateRelayPolicy.afterDisconnect(retriesSoFar: 3), .end,
                       "a phone that is gone must not leave a workout running on the wrist")
        XCTAssertEqual(RunHeartRateRelayPolicy.afterDisconnect(retriesSoFar: 10), .end)
    }

    func testAMirroringFailureEndsTheRelay() {
        XCTAssertEqual(RunHeartRateRelayPolicy.afterMirroring(succeeded: true), .keepRelaying)
        XCTAssertEqual(RunHeartRateRelayPolicy.afterMirroring(succeeded: false), .end)
    }

    /// The watch measures heart rate and nothing else for the phone's run.
    func testOnlyHeartRateIsCollected() {
        XCTAssertEqual(RunHeartRateRelayPolicy.collectedTypeIdentifiers,
                       ["HKQuantityTypeIdentifierHeartRate"])
    }
}
