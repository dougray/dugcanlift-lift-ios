import XCTest
@testable import Lift

/// When a recording starts and when it stops.
///
/// A recording starts once per presentation and stops only on an explicit
/// end. SwiftUI's `onAppear` / `onDisappear` are not that: switching the phone
/// between light and dark sent the recording screen a disappear and then an
/// appear, and the run was stopped and started again from zero. These pin that
/// a disappear stops nothing and a second appear starts nothing.
final class RecordingLifecycleTests: XCTestCase {

    func testTheFirstAppearStartsTheRecording() {
        var lifecycle = RecordingLifecycle()
        XCTAssertEqual(lifecycle.handle(.appear), .start)
        XCTAssertEqual(lifecycle.phase, .recording)
    }

    func testADisappearDoesNotStopTheRecording() {
        var lifecycle = RecordingLifecycle()
        _ = lifecycle.handle(.appear)
        XCTAssertEqual(lifecycle.handle(.disappear), .none)
        XCTAssertEqual(lifecycle.phase, .recording)
    }

    /// The light/dark switch: disappear, then appear again, mid-run.
    func testAppearingAgainDoesNotRestartTheRecording() {
        var lifecycle = RecordingLifecycle()
        _ = lifecycle.handle(.appear)
        _ = lifecycle.handle(.disappear)
        XCTAssertEqual(lifecycle.handle(.appear), .none)
        XCTAssertEqual(lifecycle.handle(.appear), .none)
        XCTAssertEqual(lifecycle.phase, .recording)
    }

    func testCancelStopsTheRecording() {
        var lifecycle = RecordingLifecycle()
        _ = lifecycle.handle(.appear)
        XCTAssertEqual(lifecycle.handle(.cancel), .stop)
        XCTAssertEqual(lifecycle.phase, .ended)
    }

    func testFinishStopsTheRecording() {
        var lifecycle = RecordingLifecycle()
        _ = lifecycle.handle(.appear)
        XCTAssertEqual(lifecycle.handle(.finish), .stop)
        XCTAssertEqual(lifecycle.phase, .ended)
    }

    /// The backstop: the screen really going away, by any route other than
    /// Cancel or Finish, must not leave location running.
    func testTheScreenGoingAwayStopsTheRecording() {
        var lifecycle = RecordingLifecycle()
        _ = lifecycle.handle(.appear)
        XCTAssertEqual(lifecycle.handle(.dismissed), .stop)
        XCTAssertEqual(lifecycle.phase, .ended)
    }

    /// Cancel or Finish stopped it already; the dismissal that follows must
    /// not stop it twice, and nothing after the end may start it again.
    func testNothingAfterTheEndStartsOrStopsAnything() {
        var lifecycle = RecordingLifecycle()
        _ = lifecycle.handle(.appear)
        _ = lifecycle.handle(.finish)
        XCTAssertEqual(lifecycle.handle(.dismissed), .none)
        XCTAssertEqual(lifecycle.handle(.appear), .none)
        XCTAssertEqual(lifecycle.handle(.cancel), .none)
        XCTAssertEqual(lifecycle.phase, .ended)
    }

    /// Dismissed before it ever appeared: there is nothing to stop, and a late
    /// appear must not start a recording for a screen that has gone.
    func testDismissedBeforeAppearingNeverStarts() {
        var lifecycle = RecordingLifecycle()
        XCTAssertEqual(lifecycle.handle(.dismissed), .none)
        XCTAssertEqual(lifecycle.handle(.appear), .none)
        XCTAssertEqual(lifecycle.phase, .ended)
    }
}
