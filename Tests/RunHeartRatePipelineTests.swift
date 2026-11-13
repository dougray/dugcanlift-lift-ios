import Foundation
import SwiftData
import XCTest
@testable import Lift

// The path from a strap or Health to the numbers on a run: what Finish stores,
// what the review re-reads, what the card shows, and the one-source-per-run
// rules, all without a radio or a Health store.

/// A Health store that answers from a list, counts how often it was asked, and
/// can hold an answer back until the test lets it go.
final class FakeHistory: HeartRateHistory, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [(from: Date, to: Date)] = []
    private var waiting: CheckedContinuation<Void, Never>?
    var result: [Int]
    var error: Error?
    var holds = false

    init(_ result: [Int] = []) { self.result = result }

    var calls: [(from: Date, to: Date)] { lock.withLock { _calls } }

    func heartRates(from: Date, to: Date) async throws -> [Int] {
        // Only the first question is held back: a second one that wrongly gets
        // through then fails an assertion instead of hanging the suite.
        let first = lock.withLock { () -> Bool in _calls.append((from, to)); return _calls.count == 1 }
        if holds && first {
            await withCheckedContinuation { continuation in
                lock.withLock { waiting = continuation }
            }
        }
        if let error { throw error }
        return result
    }

    func release() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            defer { waiting = nil }
            return waiting
        }
        continuation?.resume()
    }
}

/// A radio that is a list: which added devices it says are in range, what it
/// was asked to connect to, and the callback it was handed.
@MainActor
final class FakeCentral: HeartRateConnecting {
    var nearby: [UUID] = []
    var holdsProbe = false
    private var probeWaiting: CheckedContinuation<Void, Never>?

    private(set) var probes: [[AddedHeartRateDevice]] = []
    private(set) var connects: [(id: UUID, allowed: [AddedHeartRateDevice]?)] = []
    private(set) var disconnects = 0
    private(set) var onReading: (@MainActor (Int, Date) -> Void)?

    func inRange(_ added: [AddedHeartRateDevice], within: Duration) async -> [AddedHeartRateDevice] {
        probes.append(added)
        if holdsProbe { await withCheckedContinuation { probeWaiting = $0 } }
        return added.filter { nearby.contains($0.id) }
    }

    func connect(_ id: UUID, allowed: [AddedHeartRateDevice]?, onReading: @escaping @MainActor (Int, Date) -> Void) {
        connects.append((id, allowed))
        self.onReading = onReading
    }

    func disconnect() {
        disconnects += 1
        onReading = nil
    }

    func releaseProbe() {
        probeWaiting?.resume()
        probeWaiting = nil
    }

    /// The strap sends a reading.
    func deliver(_ bpm: Int, at: Date) { onReading?(bpm, at) }
}

private struct Boom: Error {}

@MainActor
final class RunHeartRatePipelineTests: XCTestCase {

    private var container: ModelContainer!
    private var defaults: UserDefaults!
    private let polar = AddedHeartRateDevice(id: UUID(), name: "Polar H10")
    private let wahoo = AddedHeartRateDevice(id: UUID(), name: "Wahoo Tickr")
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() {
        super.setUp()
        container = LiftStore.makeContainer(inMemory: true)
        let suite = "RunHeartRatePipelineTests.\(name.hashValue)"
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock { [defaults] in defaults?.removePersistentDomain(forName: suite) }
    }

    override func tearDown() {
        container = nil
        defaults = nil
        super.tearDown()
    }

    private func store(_ setting: HeartRateSetting, devices: [AddedHeartRateDevice]) {
        defaults.set(HeartRateStorage.string(for: setting), forKey: HeartRateStorage.settingKey)
        defaults.set(HeartRateStorage.string(for: devices), forKey: HeartRateStorage.devicesKey)
    }

    private func makeRun(history: FakeHistory? = nil,
                         central: FakeCentral? = nil,
                         save: @escaping @MainActor (ModelContext) throws -> Void = { try $0.save() }) -> ActiveRun {
        ActiveRun(history: history ?? FakeHistory(), central: central ?? FakeCentral(),
                  defaults: defaults, save: save)
    }

    private func count(_ context: ModelContext) throws -> Int {
        try context.fetchCount(FetchDescriptor<OutdoorActivity>())
    }

    /// Lets queued main-actor work run until the condition holds.
    private func settle(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<200 where !condition() { await Task.yield() }
    }

    // MARK: - What Finish stores

    func testLiveReadingsStoreTheirSummaryAndTheDevicesNameAndNeverQueryHealth() async throws {
        store(.automatic, devices: [polar])
        let central = FakeCentral()
        central.nearby = [polar.id]
        let history = FakeHistory([60, 61, 62])
        let run = makeRun(history: history, central: central)
        XCTAssertTrue(run.start(.run))
        await run.awaitHeartRateSource()
        for bpm in [140, 142, 144, 170] { central.deliver(bpm, at: .now) }

        let activity = try await run.finish(in: ModelContext(container))
        XCTAssertEqual(activity.averageBpm, 149)       // 596 / 4
        XCTAssertEqual(activity.maxBpm, 170)
        XCTAssertEqual(activity.heartRateSource, "Polar H10")
        XCTAssertEqual(history.calls.count, 0, "live readings are never second-guessed from Health")
        XCTAssertEqual(central.disconnects, 1, "Finish lets the strap go")
    }

    func testNoReadingsQueriesHealthOnceAndStoresSourceHealth() async throws {
        store(.automatic, devices: [])
        let history = FakeHistory([120, 130, 140, 150])
        let run = makeRun(history: history)
        XCTAssertTrue(run.start(.run))
        let started = try XCTUnwrap(run.recording).startedAt

        let activity = try await run.finish(in: ModelContext(container))
        XCTAssertEqual(history.calls.count, 1)
        XCTAssertEqual(history.calls.first?.from, started)
        XCTAssertEqual(history.calls.first?.to, activity.endedAt, "the window is the run's own")
        XCTAssertEqual(activity.averageBpm, 135)
        XCTAssertEqual(activity.maxBpm, 150)
        XCTAssertEqual(activity.heartRateSource, "Health")
    }

    func testAStrapWithNoReadingsAlsoFallsBackToHealth() async throws {
        store(.automatic, devices: [polar])
        let central = FakeCentral()
        central.nearby = [polar.id]
        let history = FakeHistory([100, 110])
        let run = makeRun(history: history, central: central)
        XCTAssertTrue(run.start(.walk))
        await run.awaitHeartRateSource()
        // Connected, but it never sent a pulse.

        let activity = try await run.finish(in: ModelContext(container))
        XCTAssertEqual(history.calls.count, 1)
        XCTAssertEqual(activity.heartRateSource, "Health")
        XCTAssertEqual(activity.averageBpm, 105)
    }

    func testOffStoresNothingAndQueriesNothing() async throws {
        store(.off, devices: [polar])
        let central = FakeCentral()
        central.nearby = [polar.id]
        let history = FakeHistory([120, 130])
        let run = makeRun(history: history, central: central)
        XCTAssertTrue(run.start(.run))
        await run.awaitHeartRateSource()

        let activity = try await run.finish(in: ModelContext(container))
        XCTAssertEqual(history.calls.count, 0)
        XCTAssertTrue(central.probes.isEmpty, "Off does not even look for a strap")
        XCTAssertTrue(central.connects.isEmpty)
        XCTAssertNil(activity.averageBpm)
        XCTAssertNil(activity.maxBpm)
        XCTAssertNil(activity.heartRateSource)
    }

    func testAnEmptyHealthAnswerStoresNothing() async throws {
        store(.automatic, devices: [])
        let history = FakeHistory([])
        let run = makeRun(history: history)
        XCTAssertTrue(run.start(.run))
        let activity = try await run.finish(in: ModelContext(container))
        XCTAssertEqual(history.calls.count, 1)
        XCTAssertNil(activity.averageBpm, "nothing is not a zero")
        XCTAssertNil(activity.heartRateSource)
    }

    func testAHealthFailureStillSavesTheRun() async throws {
        store(.automatic, devices: [])
        let history = FakeHistory()
        history.error = Boom()
        let run = makeRun(history: history)
        XCTAssertTrue(run.start(.run))
        let context = ModelContext(container)
        let activity = try await run.finish(in: context)
        XCTAssertNil(activity.averageBpm)
        XCTAssertEqual(try count(context), 1, "a run is never lost to a heart rate query")
    }

    // MARK: - Opened later

    private func finishedRun(endedAt: Date, figures: Bool = false) -> OutdoorActivity {
        let activity = OutdoorActivity(activityType: .run, startedAt: endedAt.addingTimeInterval(-1800))
        activity.endedAt = endedAt
        if figures {
            activity.averageBpm = 140
            activity.maxBpm = 160
            activity.heartRateSource = "Polar H10"
        }
        return activity
    }

    func testASummaryOpenedLaterFillsFromHealth() async throws {
        let activity = finishedRun(endedAt: now.addingTimeInterval(-3 * 86_400))
        let history = FakeHistory([130, 150])
        let changed = await RunHeartRateFinish.fill(activity, setting: .automatic, history: history, now: now)
        XCTAssertTrue(changed)
        XCTAssertEqual(history.calls.count, 1)
        XCTAssertEqual(history.calls.first?.from, activity.startedAt)
        XCTAssertEqual(history.calls.first?.to, activity.endedAt)
        XCTAssertEqual(activity.averageBpm, 140)
        XCTAssertEqual(activity.maxBpm, 150)
        XCTAssertEqual(activity.heartRateSource, "Health")
    }

    func testARunOlderThanSevenDaysIsNotRequeried() async {
        let activity = finishedRun(endedAt: now.addingTimeInterval(-7 * 86_400 - 1))
        let history = FakeHistory([130, 150])
        let changed = await RunHeartRateFinish.fill(activity, setting: .automatic, history: history, now: now)
        XCTAssertFalse(changed)
        XCTAssertEqual(history.calls.count, 0)
        XCTAssertNil(activity.averageBpm)
    }

    func testARunJustUnderSevenDaysIsRequeried() async {
        let activity = finishedRun(endedAt: now.addingTimeInterval(-7 * 86_400 + 60))
        let history = FakeHistory([130])
        _ = await RunHeartRateFinish.fill(activity, setting: .automatic, history: history, now: now)
        XCTAssertEqual(history.calls.count, 1)
    }

    func testARunWithFiguresIsNeverRequeried() async {
        let activity = finishedRun(endedAt: now.addingTimeInterval(-86_400), figures: true)
        let history = FakeHistory([60])
        let changed = await RunHeartRateFinish.fill(activity, setting: .automatic, history: history, now: now)
        XCTAssertFalse(changed)
        XCTAssertEqual(history.calls.count, 0)
        XCTAssertEqual(activity.averageBpm, 140)
        XCTAssertEqual(activity.heartRateSource, "Polar H10")
    }

    func testOffNeverRequeriesAnOldRunEither() async {
        let activity = finishedRun(endedAt: now.addingTimeInterval(-86_400))
        let history = FakeHistory([130])
        let changed = await RunHeartRateFinish.fill(activity, setting: .off, history: history, now: now)
        XCTAssertFalse(changed)
        XCTAssertEqual(history.calls.count, 0)
        XCTAssertNil(activity.averageBpm)
    }

    func testARunThatHasNotEndedIsNotRequeried() async {
        let activity = OutdoorActivity(activityType: .run, startedAt: now)
        let history = FakeHistory([130])
        let changed = await RunHeartRateFinish.fill(activity, setting: .automatic, history: history, now: now)
        XCTAssertFalse(changed)
        XCTAssertEqual(history.calls.count, 0)
    }

    func testAFailedRequeryChangesNothing() async {
        let activity = finishedRun(endedAt: now.addingTimeInterval(-86_400))
        let history = FakeHistory([130])
        history.error = Boom()
        let changed = await RunHeartRateFinish.fill(activity, setting: .automatic, history: history, now: now)
        XCTAssertFalse(changed)
        XCTAssertNil(activity.averageBpm)
    }

    // MARK: - Finish is async: once, and only Cancel or Finish ends a run

    func testAConcurrentSecondFinishSavesNothingMore() async throws {
        store(.automatic, devices: [])
        let history = FakeHistory([120, 140])
        history.holds = true
        let run = makeRun(history: history)
        XCTAssertTrue(run.start(.run))
        let context = ModelContext(container)

        let first = Task { @MainActor in try await run.finish(in: context).id }
        await settle { history.calls.count == 1 }
        XCTAssertTrue(run.isFinishing)

        do {
            _ = try await run.finish(in: context)
            XCTFail("a second Finish while the first waits on Health must not run")
        } catch ActiveRun.FinishError.notRecording {
            // expected
        }
        XCTAssertEqual(history.calls.count, 1, "and it does not ask Health again")

        history.release()
        let savedID = try await first.value
        XCTAssertEqual(try count(context), 1)
        XCTAssertEqual(run.justFinished?.id, savedID)
        XCTAssertNil(run.recording)
        XCTAssertFalse(run.isFinishing)
        do {
            _ = try await run.finish(in: context)
            XCTFail("nothing is recording")
        } catch ActiveRun.FinishError.notRecording {}
        XCTAssertEqual(try count(context), 1)
    }

    func testAnotherRunCannotStartWhileFinishWaitsOnHealth() async throws {
        store(.automatic, devices: [])
        let history = FakeHistory([120])
        history.holds = true
        let run = makeRun(history: history)
        XCTAssertTrue(run.start(.run))
        let first = Task { @MainActor in try await run.finish(in: ModelContext(container)).id }
        await settle { history.calls.count == 1 }
        XCTAssertFalse(run.start(.hike))
        history.release()
        _ = try await first.value
        XCTAssertTrue(run.start(.hike), "free again once the run has ended")
        run.cancel()
    }

    /// The person chose Cancel after Finish and before Health answered. The
    /// later choice wins and the run is discarded whole: nothing saved, nothing
    /// shown, no run left half-ended.
    func testCancelWhileFinishWaitsDiscardsTheRunWithNoHalfState() async throws {
        store(.automatic, devices: [])
        let history = FakeHistory([120, 140])
        history.holds = true
        let central = FakeCentral()
        let run = makeRun(history: history, central: central)
        XCTAssertTrue(run.start(.run))
        let recording = try XCTUnwrap(run.recording)
        let context = ModelContext(container)

        let finishing = Task { @MainActor in try await run.finish(in: context).id }
        await settle { history.calls.count == 1 }
        run.cancel()
        XCTAssertNil(run.recording)
        XCTAssertFalse(run.isFinishing)
        XCTAssertFalse(recording.tracker.isTracking)

        history.release()
        do {
            _ = try await finishing.value
            XCTFail("a cancelled run is not saved")
        } catch ActiveRun.FinishError.notRecording {}
        XCTAssertEqual(try count(context), 0)
        XCTAssertNil(run.justFinished)
        XCTAssertNil(run.recording)
    }

    /// A cancelled run's late Finish must not touch the run that replaced it.
    func testAFinishFromACancelledRunDoesNotEndTheNextRun() async throws {
        store(.automatic, devices: [])
        let history = FakeHistory([120])
        history.holds = true
        let run = makeRun(history: history)
        XCTAssertTrue(run.start(.run))
        let context = ModelContext(container)
        let old = Task { @MainActor in try await run.finish(in: context).id }
        await settle { history.calls.count == 1 }
        run.cancel()
        XCTAssertTrue(run.start(.walk))
        let next = run.recording

        history.release()
        _ = try? await old.value
        XCTAssertTrue(run.recording === next, "the new run is still recording")
        XCTAssertFalse(run.isFinishing)
        XCTAssertEqual(try count(context), 0)
        run.cancel()
    }

    func testAFailedSaveKeepsTheRunRecordingAndARetrySavesOnce() async throws {
        store(.automatic, devices: [])
        let history = FakeHistory([120, 140])
        var failures = 1
        let run = makeRun(history: history, save: { context in
            if failures > 0 { failures -= 1; throw Boom() }
            try context.save()
        })
        XCTAssertTrue(run.start(.run))
        let recording = try XCTUnwrap(run.recording)
        let context = ModelContext(container)

        do {
            _ = try await run.finish(in: context)
            XCTFail("the save failed")
        } catch is Boom {}
        XCTAssertTrue(run.recording === recording)
        XCTAssertTrue(recording.tracker.isTracking)
        XCTAssertFalse(run.isFinishing, "a retry is allowed")
        XCTAssertNil(run.justFinished)
        XCTAssertEqual(try count(context), 0)

        let activity = try await run.finish(in: context)
        XCTAssertEqual(try count(context), 1, "the backed-out insert did not save twice")
        XCTAssertEqual(activity.averageBpm, 130)
        XCTAssertNil(run.recording)
    }

    func testFinishBeforeTheSourceWasPickedUsesHealthAndNeverConnectsLate() async throws {
        store(.automatic, devices: [polar])
        let central = FakeCentral()
        central.nearby = [polar.id]
        central.holdsProbe = true
        let history = FakeHistory([100, 120])
        let run = makeRun(history: history, central: central)
        XCTAssertTrue(run.start(.run))
        await settle { central.probes.count == 1 }

        let activity = try await run.finish(in: ModelContext(container))
        central.releaseProbe()
        await Task.yield()
        await Task.yield()
        XCTAssertTrue(central.connects.isEmpty, "a run that is over connects to nothing")
        XCTAssertEqual(activity.heartRateSource, "Health")
    }

    func testCancelDuringTheProbeConnectsToNothing() async throws {
        store(.automatic, devices: [polar])
        let central = FakeCentral()
        central.nearby = [polar.id]
        central.holdsProbe = true
        let run = makeRun(central: central)
        XCTAssertTrue(run.start(.run))
        await settle { central.probes.count == 1 }
        run.cancel()
        central.releaseProbe()
        await run.awaitHeartRateSource()
        XCTAssertTrue(central.connects.isEmpty)
        XCTAssertNil(run.heartRate)
    }

    // MARK: - One source per run

    func testTheSourceIsPickedOnceAtStartFromTheAddedDevicesAndNothingWider() async throws {
        store(.automatic, devices: [polar, wahoo])
        let central = FakeCentral()
        central.nearby = [wahoo.id]   // the first added is not here; the second is
        let run = makeRun(central: central)
        XCTAssertTrue(run.start(.run))
        await run.awaitHeartRateSource()
        addTeardownBlock { @MainActor in run.cancel() }

        XCTAssertEqual(central.probes, [[polar, wahoo]], "looked once, among the added list")
        XCTAssertEqual(central.connects.count, 1)
        XCTAssertEqual(central.connects.first?.id, wahoo.id)
        XCTAssertEqual(central.connects.first?.allowed, [polar, wahoo], "never widened beyond what was added")
        XCTAssertEqual(run.heartRate?.source, .device(wahoo.id, name: "Wahoo Tickr"))
    }

    func testAutomaticWithNothingAddedNeverTouchesTheRadio() async throws {
        store(.automatic, devices: [])
        let central = FakeCentral()
        let run = makeRun(central: central)
        XCTAssertTrue(run.start(.run))
        await run.awaitHeartRateSource()
        addTeardownBlock { @MainActor in run.cancel() }
        XCTAssertTrue(central.probes.isEmpty, "no added device, no Bluetooth prompt")
        XCTAssertTrue(central.connects.isEmpty)
        XCTAssertNil(run.heartRate?.source)
    }

    func testAChosenDeviceOutOfRangeIsNotReplacedByAnother() async throws {
        store(.device(polar.id), devices: [polar, wahoo])
        let central = FakeCentral()
        central.nearby = [wahoo.id]
        let run = makeRun(central: central)
        XCTAssertTrue(run.start(.run))
        await run.awaitHeartRateSource()
        addTeardownBlock { @MainActor in run.cancel() }
        XCTAssertTrue(central.connects.isEmpty)
        XCTAssertNil(run.heartRate?.source)
    }

    func testAStrapThatConnectsAfterTheWindowIsNotUsedLive() async throws {
        store(.automatic, devices: [polar])
        let central = FakeCentral()
        central.nearby = []            // not in range for the 3 s look
        let history = FakeHistory([110, 130])
        let run = makeRun(history: history, central: central)
        XCTAssertTrue(run.start(.run))
        await run.awaitHeartRateSource()

        // It turns up a minute later. Nothing was connected, so nothing can speak.
        central.nearby = [polar.id]
        XCTAssertTrue(central.connects.isEmpty)
        central.deliver(150, at: .now)
        XCTAssertTrue(run.heartRate?.readings.isEmpty ?? true)

        let activity = try await run.finish(in: ModelContext(container))
        XCTAssertEqual(history.calls.count, 1)
        XCTAssertEqual(activity.heartRateSource, "Health", "Health fills the summary after the run")
        XCTAssertEqual(central.connects.count, 0)
    }

    /// The pipeline-level rule, and one that can fail: the number goes away
    /// after ten silent seconds and comes back from the same strap, and nothing
    /// along the way -- a stale number, a second strap coming into range, the
    /// watch -- picks a second source or connects again.
    func testADroppedSourceIsReconnectedNotSwappedThroughThePipeline() async throws {
        store(.automatic, devices: [polar, wahoo])
        let central = FakeCentral()
        central.nearby = [polar.id]
        let run = makeRun(central: central)
        XCTAssertTrue(run.start(.run))
        await run.awaitHeartRateSource()
        addTeardownBlock { @MainActor in run.cancel() }
        let session = try XCTUnwrap(run.heartRate)
        let source = LiveHeartRateSource.device(polar.id, name: "Polar H10")
        XCTAssertEqual(session.source, source)

        let t0 = Date(timeIntervalSince1970: 1_900_000_000)
        central.deliver(140, at: t0)
        XCTAssertEqual(run.liveHeartRate(now: t0.addingTimeInterval(2))?.number, "140 bpm")

        // The strap drops: ten seconds of nothing hides the number.
        XCTAssertEqual(run.liveHeartRate(now: t0.addingTimeInterval(11))?.number, "—")
        XCTAssertNil(session.shown(now: t0.addingTimeInterval(11)))

        // Meanwhile another strap that nobody picked comes into range.
        central.nearby = [polar.id, wahoo.id]

        // The same strap comes back (the radio reconnects it; the callback is the same).
        central.deliver(143, at: t0.addingTimeInterval(20))
        XCTAssertEqual(run.liveHeartRate(now: t0.addingTimeInterval(21))?.number, "143 bpm")

        XCTAssertTrue(run.heartRate === session, "the same session")
        XCTAssertEqual(session.source, source, "the source never changed")
        XCTAssertEqual(session.readings, [140, 143])
        XCTAssertEqual(central.connects.count, 1, "connected once, to the one picked")
        XCTAssertEqual(central.connects.first?.id, polar.id)
        XCTAssertEqual(central.probes.count, 1, "and never looked again")
        XCTAssertEqual(run.liveHeartRate(now: t0.addingTimeInterval(21))?.source, "from Polar H10")
    }

    // MARK: - What the card shows

    func testTheLiveNumberDisappearsAtTenSecondsWithNothingElseChanging() async throws {
        store(.automatic, devices: [polar])
        let central = FakeCentral()
        central.nearby = [polar.id]
        let run = makeRun(central: central)
        XCTAssertTrue(run.start(.run))
        await run.awaitHeartRateSource()
        addTeardownBlock { @MainActor in run.cancel() }
        let at = Date(timeIntervalSince1970: 1_900_000_000)
        central.deliver(142, at: at)

        XCTAssertEqual(run.liveHeartRate(now: at)?.number, "142 bpm")
        XCTAssertEqual(run.liveHeartRate(now: at.addingTimeInterval(10))?.number, "142 bpm")
        XCTAssertEqual(run.liveHeartRate(now: at.addingTimeInterval(10.5))?.number, "—",
                       "the clock moved and nothing else did")
        XCTAssertEqual(run.liveHeartRate(now: at.addingTimeInterval(10.5))?.source, "from Polar H10")
    }

    func testNoSourceMeansNoHeartRateLineAtAll() async throws {
        store(.off, devices: [])
        let run = makeRun()
        XCTAssertTrue(run.start(.run))
        await run.awaitHeartRateSource()
        addTeardownBlock { @MainActor in run.cancel() }
        XCTAssertNil(run.liveHeartRate(now: .now))
    }

    func testTheWordsAreVerbatim() {
        XCTAssertEqual(RunHeartRateWords.live(142), "142 bpm")
        XCTAssertEqual(RunHeartRateWords.live(nil), "—")
        XCTAssertEqual(RunHeartRateWords.source("Polar H10"), "from Polar H10")
        XCTAssertEqual(RunHeartRateWords.source("Apple Watch"), "from Apple Watch")
        XCTAssertEqual(RunHeartRateWords.source("Health"), "from Health, after the run")
        XCTAssertEqual(RunHeartRateWords.summary(average: 141, max: 168), "Avg 141 · Max 168 bpm")
        XCTAssertNil(RunHeartRateWords.summary(average: nil, max: 168))
        XCTAssertNil(RunHeartRateWords.summary(average: 141, max: nil))
        XCTAssertNil(RunHeartRateWords.summary(average: 0, max: 0), "blank is never a zero on screen")
    }

    func testASavedRunsLineReadsSummaryAndSource() {
        let activity = finishedRun(endedAt: now, figures: true)
        let line = RunHeartRateWords.line(for: activity)
        XCTAssertEqual(line?.summary, "Avg 140 · Max 160 bpm")
        XCTAssertEqual(line?.source, "from Polar H10")
        XCTAssertNil(RunHeartRateWords.line(for: finishedRun(endedAt: now)))
    }

    // MARK: - No retain cycle

    /// The strap's callback is held by the radio for the length of a run. It
    /// must hold the session, weakly, and never the object that owns the run.
    func testTheReadingCallbackDoesNotKeepTheRunAlive() async throws {
        store(.automatic, devices: [polar])
        let central = FakeCentral()
        central.nearby = [polar.id]
        weak var weakRun: ActiveRun?
        weak var weakSession: RunHeartRateSession?
        do {
            let run = makeRun(central: central)
            weakRun = run
            XCTAssertTrue(run.start(.run))
            await run.awaitHeartRateSource()
            weakSession = run.heartRate
            XCTAssertNotNil(central.onReading)
            run.cancel()
        }
        // Cancel let the strap go, which drops the callback; hold one again to
        // prove the callback alone does not retain the owner.
        XCTAssertNil(weakRun, "the run's owner is gone")
        XCTAssertNil(weakSession)
        XCTAssertNil(central.onReading)
    }

    func testALiveCallbackAloneDoesNotRetainTheOwner() async throws {
        store(.automatic, devices: [polar])
        let central = FakeCentral()
        central.nearby = [polar.id]
        weak var weakRun: ActiveRun?
        var held: (@MainActor (Int, Date) -> Void)?
        do {
            let run = makeRun(central: central)
            weakRun = run
            XCTAssertTrue(run.start(.run))
            await run.awaitHeartRateSource()
            held = central.onReading     // what the radio holds mid-run
            run.cancel()
        }
        XCTAssertNotNil(held)
        XCTAssertNil(weakRun, "a radio holding the callback does not hold the run")
        held?(150, .now)    // a late reading after the run is gone is harmless
    }
}
