import XCTest
@testable import LiftKit

final class PlanRequestGateTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_758_406_000)

    func testTheFirstRequestGoes() {
        var gate = PlanRequestGate()
        XCTAssertTrue(gate.shouldRequest(reachable: true, now: t0))
    }

    /// The double the spike measured: the phone becomes reachable and the
    /// app becomes active in the same millisecond, and each asked.
    func testTwoTriggersTogetherAskOnce() {
        var gate = PlanRequestGate()
        XCTAssertTrue(gate.shouldRequest(reachable: true, now: t0))
        XCTAssertFalse(gate.shouldRequest(reachable: true, now: t0.addingTimeInterval(0.001)))
    }

    func testALiveRequestSuppressesAQueuedOneToo() {
        var gate = PlanRequestGate()
        XCTAssertTrue(gate.shouldRequest(reachable: true, now: t0))
        XCTAssertFalse(gate.shouldRequest(reachable: false, now: t0.addingTimeInterval(2)))
    }

    /// Queued while out of reach, then the phone comes back: take the fast
    /// path rather than wait on a queue that may not deliver for hours.
    func testAQueuedRequestDoesNotBlockTheFastPath() {
        var gate = PlanRequestGate()
        XCTAssertTrue(gate.shouldRequest(reachable: false, now: t0))
        XCTAssertTrue(gate.shouldRequest(reachable: true, now: t0.addingTimeInterval(1)))
        // ...and that live one now covers the window.
        XCTAssertFalse(gate.shouldRequest(reachable: true, now: t0.addingTimeInterval(2)))
    }

    func testQueuedRequestsDoNotPileUp() {
        var gate = PlanRequestGate()
        XCTAssertTrue(gate.shouldRequest(reachable: false, now: t0))
        XCTAssertFalse(gate.shouldRequest(reachable: false, now: t0.addingTimeInterval(3)))
    }

    func testTheWindowExpires() {
        var gate = PlanRequestGate()
        XCTAssertTrue(gate.shouldRequest(reachable: true, now: t0))
        XCTAssertFalse(gate.shouldRequest(reachable: true,
                                          now: t0.addingTimeInterval(PlanRequestGate.window - 0.01)))
        XCTAssertTrue(gate.shouldRequest(reachable: true,
                                         now: t0.addingTimeInterval(PlanRequestGate.window)))
    }

    func testATapAlwaysGoesAndRestartsTheWindow() {
        var gate = PlanRequestGate()
        XCTAssertTrue(gate.shouldRequest(reachable: true, now: t0))
        XCTAssertTrue(gate.shouldRequest(reachable: true, now: t0.addingTimeInterval(1), force: true))
        XCTAssertFalse(gate.shouldRequest(reachable: true, now: t0.addingTimeInterval(1 + PlanRequestGate.window - 1)))
    }

    /// A clock that moved backwards (a watch restoring its time after a flat
    /// battery) must not leave the gate shut for ever.
    func testAClockThatWentBackwardsDoesNotSuppressForever() {
        var gate = PlanRequestGate()
        XCTAssertTrue(gate.shouldRequest(reachable: true, now: t0))
        let earlier = t0.addingTimeInterval(-86_400)
        XCTAssertTrue(gate.shouldRequest(reachable: true, now: earlier))
    }

    /// Measured on the simulator pair: the phone went out of reach in the
    /// millisecond after a live request, `sendMessage` failed with 7007 and
    /// the request was queued, and the phone was back 0.3 s later. The next
    /// trigger must get to ask again rather than wait on a reply that the
    /// failed message will not bring.
    func testALiveRequestThatFellBackToTheQueueNoLongerHoldsOffTheFastPath() {
        var gate = PlanRequestGate()
        XCTAssertTrue(gate.shouldRequest(reachable: true, now: t0))
        gate.liveRequestFellBackToQueue()
        XCTAssertFalse(gate.shouldRequest(reachable: false, now: t0.addingTimeInterval(0.1)))
        XCTAssertTrue(gate.shouldRequest(reachable: true, now: t0.addingTimeInterval(0.4)))
        XCTAssertFalse(gate.shouldRequest(reachable: true, now: t0.addingTimeInterval(0.5)))
    }

    // MARK: - ReachabilityTracker

    /// Activation finds the phone reachable, then sessionReachabilityDidChange
    /// reports the same thing: one change, not two.
    func testActivationThenTheSameReachabilityIsOneChange() {
        var tracker = ReachabilityTracker()
        XCTAssertEqual(tracker.update(true), true)
        XCTAssertNil(tracker.update(true))
    }

    func testEveryRealChangeIsReported() {
        var tracker = ReachabilityTracker()
        XCTAssertEqual(tracker.update(false), false)
        XCTAssertNil(tracker.update(false))
        XCTAssertEqual(tracker.update(true), true)
        XCTAssertEqual(tracker.update(false), false)
        XCTAssertEqual(tracker.update(true), true)
    }
}
