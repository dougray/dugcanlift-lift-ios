import XCTest
@testable import LiftKit

/// Finish Workout must lead back to the start screen. A finished draft that
/// is still held (the model clears it, but nothing should depend on that
/// alone) routes to `.start`, never back onto the workout pager.
final class WatchRouteTests: XCTestCase {

    func testNoDraftShowsStart() {
        XCTAssertEqual(WatchRoute.resolve(draft: nil, isRecordingOutdoor: false), .start)
    }

    func testInProgressDraftShowsWorkout() {
        let draft = WorkoutDraft(name: "Push")
        XCTAssertEqual(WatchRoute.resolve(draft: draft, isRecordingOutdoor: false), .workout)
    }

    func testFinishedDraftReturnsToStart() {
        var draft = WorkoutDraft(name: "Push")
        draft.addExercise(refID: "bench-barbell", name: "Bench Press")
        XCTAssertTrue(draft.finish())
        XCTAssertEqual(WatchRoute.resolve(draft: draft, isRecordingOutdoor: false), .start)
    }

    func testOutdoorRecordingTakesPriority() {
        let draft = WorkoutDraft(name: "Push")
        XCTAssertEqual(WatchRoute.resolve(draft: draft, isRecordingOutdoor: true), .outdoorActivity)
        XCTAssertEqual(WatchRoute.resolve(draft: nil, isRecordingOutdoor: true), .outdoorActivity)
    }

    func testFinishingTwiceIsRejected() {
        // The second tap on a stale Finish button must not re-finish (and so
        // must not produce a second SESSION_FINISHED revision).
        var draft = WorkoutDraft(name: "Push")
        XCTAssertTrue(draft.finish())
        let revision = draft.revision
        XCTAssertFalse(draft.finish())
        XCTAssertEqual(draft.revision, revision)
    }
}
