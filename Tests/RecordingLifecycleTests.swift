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

    /// Discard: Cancel stops the run, then the cover's own dismissal follows
    /// and must stop nothing a second time.
    func testCancelThenTheDismissalStopsOnce() {
        var lifecycle = RecordingLifecycle()
        _ = lifecycle.handle(.appear)
        XCTAssertEqual(lifecycle.handle(.cancel), .stop)
        XCTAssertEqual(lifecycle.handle(.dismissed), .none)
        XCTAssertEqual(lifecycle.phase, .ended)
    }

    func testCancelBeforeAppearingEndsWithoutStopping() {
        var lifecycle = RecordingLifecycle()
        XCTAssertEqual(lifecycle.handle(.cancel), .none)
        XCTAssertEqual(lifecycle.phase, .ended)
        XCTAssertEqual(lifecycle.handle(.appear), .none)
    }

    func testFinishBeforeAppearingEndsWithoutStopping() {
        var lifecycle = RecordingLifecycle()
        XCTAssertEqual(lifecycle.handle(.finish), .none)
        XCTAssertEqual(lifecycle.phase, .ended)
        XCTAssertEqual(lifecycle.handle(.appear), .none)
    }

    /// A disappear before the first appear is not an end: the screen has not
    /// shown yet, and its first appear still starts the run.
    func testDisappearBeforeAppearingChangesNothing() {
        var lifecycle = RecordingLifecycle()
        XCTAssertEqual(lifecycle.handle(.disappear), .none)
        XCTAssertEqual(lifecycle.phase, .idle)
        XCTAssertEqual(lifecycle.handle(.appear), .start)
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

/// The recording object itself, with a real `LocationTracker`: the light/dark
/// rebuild's disappear-then-appear must leave the same run going, with the
/// same start time.
@MainActor
final class OutdoorRecordingTests: XCTestCase {

    func testDisappearingAndAppearingAgainKeepsTheSameRun() {
        let recording = OutdoorRecording(activityType: .run)
        addTeardownBlock { @MainActor in recording.handle(.cancel) }

        recording.handle(.appear)
        let startedAt = recording.startedAt
        XCTAssertTrue(recording.tracker.isTracking)
        XCTAssertEqual(recording.phase, .recording)

        recording.handle(.disappear)
        recording.handle(.appear)

        XCTAssertEqual(recording.startedAt, startedAt)
        XCTAssertTrue(recording.tracker.isTracking)
        XCTAssertEqual(recording.phase, .recording)
    }

    func testCancelStopsTheTracker() {
        let recording = OutdoorRecording(activityType: .walk)
        recording.handle(.appear)
        recording.handle(.cancel)
        XCTAssertFalse(recording.tracker.isTracking)
        XCTAssertEqual(recording.phase, .ended)
    }
}
