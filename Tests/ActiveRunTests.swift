import SwiftData
import XCTest
@testable import Lift

@MainActor
final class ActiveRunTests: XCTestCase {

    private func makeContext() -> ModelContext {
        ModelContext(LiftStore.makeContainer(inMemory: true))
    }

    func testAnotherRunCannotStartWhileOneRecords() {
        let run = ActiveRun()
        XCTAssertTrue(run.start(.run))
        addTeardownBlock { @MainActor in run.cancel() }
        let first = run.recording
        XCTAssertFalse(run.start(.hike))
        XCTAssertTrue(run.recording === first)
        XCTAssertEqual(run.recording?.activityType, .run)
    }

    func testCloseKeepsTheTrackerRunning() throws {
        let run = ActiveRun()
        XCTAssertTrue(run.start(.walk))
        addTeardownBlock { @MainActor in run.cancel() }
        let recording = try XCTUnwrap(run.recording)
        recording.handle(.appear)
        XCTAssertTrue(run.isScreenShown)

        run.close()
        XCTAssertFalse(run.isScreenShown)
        XCTAssertNotNil(run.recording)
        XCTAssertTrue(recording.tracker.isTracking)
        XCTAssertEqual(recording.phase, .recording)

        run.open()
        XCTAssertTrue(run.isScreenShown)
        XCTAssertTrue(run.recording === recording)
    }

    func testFinishFromTheCardSavesOnce() throws {
        let context = makeContext()
        let run = ActiveRun()
        XCTAssertTrue(run.start(.run))
        let recording = try XCTUnwrap(run.recording)
        recording.handle(.appear)
        run.close()

        let activity = try run.finish(in: context)
        XCTAssertNil(run.recording)
        XCTAssertFalse(recording.tracker.isTracking)
        XCTAssertTrue(run.justFinished === activity)
        XCTAssertThrowsError(try run.finish(in: context))
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<OutdoorActivity>()), 1)
    }

    func testCancelSavesNothing() throws {
        let context = makeContext()
        let run = ActiveRun()
        XCTAssertTrue(run.start(.hike))
        let recording = try XCTUnwrap(run.recording)
        recording.handle(.appear)

        run.cancel()
        XCTAssertNil(run.recording)
        XCTAssertFalse(run.isScreenShown)
        XCTAssertFalse(recording.tracker.isTracking)
        XCTAssertNil(run.justFinished)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<OutdoorActivity>()), 0)
        XCTAssertTrue(run.start(.run), "a new run can start once the last ended")
        run.cancel()
    }
}
