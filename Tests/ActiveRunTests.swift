import SwiftData
import XCTest
@testable import Lift

@MainActor
final class ActiveRunTests: XCTestCase {

    /// Held by the test: a `ModelContext` does not keep its container alive.
    private var container: ModelContainer!

    override func setUp() {
        super.setUp()
        container = LiftStore.makeContainer(inMemory: true)
    }

    override func tearDown() {
        container = nil
        super.tearDown()
    }

    private func makeContext() -> ModelContext {
        ModelContext(container)
    }

    /// No Health store and no radio: these tests are about the run's lifecycle.
    private func makeRun() -> ActiveRun {
        ActiveRun(history: FakeHistory(), central: FakeCentral(),
                  defaults: UserDefaults(suiteName: "ActiveRunTests") ?? .standard)
    }

    func testAnotherRunCannotStartWhileOneRecords() {
        let run = makeRun()
        XCTAssertTrue(run.start(.run))
        addTeardownBlock { @MainActor in run.cancel() }
        let first = run.recording
        XCTAssertFalse(run.start(.hike))
        XCTAssertTrue(run.recording === first)
        XCTAssertEqual(run.recording?.activityType, .run)
    }

    func testCloseKeepsTheTrackerRunning() throws {
        let run = makeRun()
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

    func testFinishFromTheCardSavesOnce() async throws {
        let context = makeContext()
        let run = makeRun()
        XCTAssertTrue(run.start(.run))
        let recording = try XCTUnwrap(run.recording)
        recording.handle(.appear)
        run.close()

        let activity = try await run.finish(in: context)
        XCTAssertNil(run.recording)
        XCTAssertFalse(recording.tracker.isTracking)
        XCTAssertTrue(run.justFinished === activity)
        do {
            _ = try await run.finish(in: context)
            XCTFail("a second Finish after the save must throw")
        } catch ActiveRun.FinishError.notRecording {}
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<OutdoorActivity>()), 1)
    }

    func testCancelSavesNothing() throws {
        let context = makeContext()
        let run = makeRun()
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

    /// A presentation SwiftUI never showed must not strand the run: the
    /// tracker is already going, and Finish on the card still ends it.
    func testARunWhoseScreenNeverAppearedIsNotStranded() async throws {
        let context = makeContext()
        let run = makeRun()
        XCTAssertTrue(run.start(.run))
        let recording = try XCTUnwrap(run.recording)
        // No `.appear` is ever sent, as when the cover is dropped.
        XCTAssertTrue(recording.tracker.isTracking)
        XCTAssertEqual(recording.phase, .recording)

        _ = try await run.finish(in: context)
        XCTAssertNil(run.recording)
        XCTAssertFalse(recording.tracker.isTracking)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<OutdoorActivity>()), 1)
    }

    /// Open on a screen that claims to be shown (a dropped presentation)
    /// presents it again, a turn later.
    func testOpenRepresentsADroppedScreen() async throws {
        let run = makeRun()
        XCTAssertTrue(run.start(.walk))
        addTeardownBlock { @MainActor in run.cancel() }
        XCTAssertTrue(run.isScreenShown)

        run.open()
        XCTAssertFalse(run.isScreenShown, "taken down first so it can be put up again")
        await Task.yield()
        await Task.yield()
        XCTAssertTrue(run.isScreenShown)
        XCTAssertNotNil(run.recording)
    }

    func testOpenWithNothingRecordingDoesNothing() {
        let run = makeRun()
        run.open()
        XCTAssertFalse(run.isScreenShown)
    }
}
