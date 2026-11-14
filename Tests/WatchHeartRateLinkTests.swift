import Foundation
import SwiftData
import XCTest
@testable import Lift

// Path B: LIFT on the Apple Watch measures a run the phone records. The rules,
// as values and through `ActiveRun`, without a watch.

/// A watch that is a list: how often it was asked to start and stop, for
/// which run, and the callback it was handed. It follows the real link's run
/// rule (`WatchLinkRuns`), can fail to start, or hold its answers back.
@MainActor
final class FakeWatch: WatchHeartRateLinking {
    var onReading: (@MainActor (Int, Date) -> Void)?
    var failsToStart = false
    var holdsStart = false
    private var startWaiting: [CheckedContinuation<Void, Never>] = []
    private var runs = WatchLinkRuns()
    private(set) var starts = 0
    /// Every stop call, stale or not.
    private(set) var stops = 0
    /// Stops that ended the watch for the run it was measuring.
    private(set) var effectiveStops = 0
    private(set) var startedRuns: [UUID] = []

    var current: UUID? { runs.current }

    struct NotReachable: Error {}

    func start(run: UUID) async throws {
        starts += 1
        startedRuns.append(run)
        runs.began(run)
        if holdsStart { await withCheckedContinuation { startWaiting.append($0) } }
        if failsToStart {
            _ = runs.stop(run)
            throw NotReachable()
        }
    }

    func stop(run: UUID) {
        stops += 1
        guard runs.stop(run) else { return }
        effectiveStops += 1
        onReading = nil
    }

    /// Lets the oldest held start answer.
    func releaseStart() {
        guard !startWaiting.isEmpty else { return }
        startWaiting.removeFirst().resume()
    }

    /// The watch sends a reading.
    func deliver(_ bpm: Int, at: Date) { onReading?(bpm, at) }
}

@MainActor
struct FakeWatchAvailability: WatchAvailability {
    var isWatchAppReady: Bool
    init(_ ready: Bool) { isWatchAppReady = ready }
}

@MainActor
final class WatchHeartRateLinkTests: XCTestCase {

    private var container: ModelContainer!
    private var defaults: UserDefaults!
    private let polar = AddedHeartRateDevice(id: UUID(), name: "Polar H10")

    override func setUp() {
        super.setUp()
        container = LiftStore.makeContainer(inMemory: true)
        let suite = "WatchHeartRateLinkTests.\(name.hashValue)"
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock { [defaults] in defaults?.removePersistentDomain(forName: suite) }
    }

    override func tearDown() {
        container = nil
        defaults = nil
        super.tearDown()
    }

    private func store(_ setting: HeartRateSetting, devices: [AddedHeartRateDevice] = []) {
        defaults.set(HeartRateStorage.string(for: setting), forKey: HeartRateStorage.settingKey)
        defaults.set(HeartRateStorage.string(for: devices), forKey: HeartRateStorage.devicesKey)
    }

    private func makeRun(history: FakeHistory = FakeHistory(), central: FakeCentral? = nil,
                         watch: FakeWatch, ready: Bool = true) -> ActiveRun {
        ActiveRun(history: history, central: central ?? FakeCentral(), watch: watch,
                  watchAvailability: FakeWatchAvailability(ready), defaults: defaults)
    }

    // MARK: - The values

    func testTheWatchIsReadyOnlyPairedInstalledAndActivated() {
        XCTAssertTrue(WatchAvailabilityRule.ready(supported: true, activated: true, paired: true,
                                                  installed: true, healthAvailable: true))
        XCTAssertFalse(WatchAvailabilityRule.ready(supported: true, activated: true, paired: false,
                                                   installed: true, healthAvailable: true))
        XCTAssertFalse(WatchAvailabilityRule.ready(supported: true, activated: true, paired: true,
                                                   installed: false, healthAvailable: true),
                       "paired, but LIFT is not on it")
        XCTAssertFalse(WatchAvailabilityRule.ready(supported: true, activated: false, paired: true,
                                                   installed: true, healthAvailable: true),
                       "isPaired means nothing before the session activates")
        XCTAssertFalse(WatchAvailabilityRule.ready(supported: false, activated: true, paired: true,
                                                   installed: true, healthAvailable: true))
        XCTAssertFalse(WatchAvailabilityRule.ready(supported: true, activated: true, paired: true,
                                                   installed: true, healthAvailable: false))
    }

    func testSettingsShowsTheWatchRowWhenReadyOrChosen() {
        XCTAssertTrue(HeartRateWatchRow.shows(ready: true, setting: .automatic))
        XCTAssertFalse(HeartRateWatchRow.shows(ready: false, setting: .automatic))
        XCTAssertFalse(HeartRateWatchRow.shows(ready: false, setting: .off))
        XCTAssertTrue(HeartRateWatchRow.shows(ready: false, setting: .watch),
                      "a chosen watch that is away still shows what was chosen")
    }

    func testAWatchThatCannotBeAskedIsNoSource() {
        XCTAssertEqual(WatchLinkStart.source(started: true), .watch)
        XCTAssertNil(WatchLinkStart.source(started: false))
    }

    /// `startWatchApp` saying false with no error is still a watch that never
    /// launched.
    func testAFalseWithNoErrorIsAFailedStart() {
        struct Boom: Error {}
        XCTAssertNil(WatchLinkStart.failure(success: true, error: nil))
        XCTAssertNotNil(WatchLinkStart.failure(success: false, error: nil))
        XCTAssertTrue(WatchLinkStart.failure(success: false, error: Boom()) is Boom)
        XCTAssertTrue(WatchLinkStart.failure(success: true, error: Boom()) is Boom,
                      "an error is a failure whatever the flag says")
    }

    func testAStaleStopNeverStopsTheNextRunsWatch() {
        let a = UUID(), b = UUID()
        var runs = WatchLinkRuns()
        runs.began(a)
        XCTAssertTrue(runs.stop(a))
        runs.began(b)
        XCTAssertFalse(runs.stop(a), "run A's late stop")
        XCTAssertEqual(runs.current, b)
        XCTAssertTrue(runs.wantsWatch)
        XCTAssertTrue(runs.stop(b))
        XCTAssertFalse(runs.wantsWatch)
        XCTAssertFalse(runs.stop(b), "twice is once")
    }

    func testAMirroredSessionNobodyAskedForIsEnded() {
        XCTAssertEqual(WatchMirrorDecision.decide(runWantsWatch: true), .adopt)
        XCTAssertEqual(WatchMirrorDecision.decide(runWantsWatch: false), .end)
    }

    /// What Finish stores is what the card and the summary say.
    func testTheStoredNameIsWhatTheCardSays() {
        XCTAssertEqual(RunHeartRateFinish.watchSource, "Apple Watch")
        XCTAssertEqual(LiveHeartRateSource.watch.storedName, RunHeartRateFinish.watchSource)
        XCTAssertEqual(RunHeartRateWords.source(LiveHeartRateSource.watch.storedName), "from Apple Watch")
    }

    // MARK: - Through a run

    func testWatchReadingsStoreAppleWatchAndNeverQueryHealth() async throws {
        store(.watch)
        let watch = FakeWatch()
        let history = FakeHistory([60, 61])
        let run = makeRun(history: history, watch: watch)
        XCTAssertTrue(run.start(.run))
        await run.awaitHeartRateSource()
        XCTAssertEqual(run.heartRate?.source, .watch)
        XCTAssertEqual(watch.starts, 1)
        let at = Date.now
        for bpm in [140, 150, 160] { watch.deliver(bpm, at: at) }
        XCTAssertEqual(run.liveHeartRate(now: at)?.number, "160 bpm")
        XCTAssertEqual(run.liveHeartRate(now: at)?.source, "from Apple Watch")

        let activity = try await run.finish(in: ModelContext(container))
        XCTAssertEqual(activity.heartRateSource, "Apple Watch")
        XCTAssertEqual(activity.averageBpm, 150)
        XCTAssertEqual(activity.maxBpm, 160)
        XCTAssertEqual(history.calls.count, 0, "live readings are never second-guessed from Health")
        XCTAssertEqual(watch.effectiveStops, 1, "Finish ends the watch's session")
        XCTAssertNil(watch.onReading)
    }

    func testAWatchThatSentNothingFallsToHealthAfterTheRun() async throws {
        store(.watch)
        let watch = FakeWatch()
        let history = FakeHistory([120, 130])
        let run = makeRun(history: history, watch: watch)
        XCTAssertTrue(run.start(.run))
        await run.awaitHeartRateSource()
        XCTAssertEqual(run.heartRate?.source, .watch)
        XCTAssertEqual(run.liveHeartRate(now: .now)?.number, "—")

        let activity = try await run.finish(in: ModelContext(container))
        XCTAssertEqual(history.calls.count, 1)
        XCTAssertEqual(activity.heartRateSource, "Health")
        XCTAssertEqual(activity.averageBpm, 125)
    }

    func testAWatchThatCannotStartLeavesTheRunWithNoSourceAndFinishStillWorks() async throws {
        store(.automatic, devices: [polar])
        let watch = FakeWatch()
        watch.failsToStart = true
        let central = FakeCentral()          // the strap is not in range
        let history = FakeHistory([110, 130])
        let run = makeRun(history: history, central: central, watch: watch)
        XCTAssertTrue(run.start(.run))
        await run.awaitHeartRateSource()
        XCTAssertEqual(watch.starts, 1)
        XCTAssertNotNil(run.heartRate, "the run has its session, with no source")
        XCTAssertNil(run.heartRate?.source)
        XCTAssertNil(run.liveHeartRate(now: .now), "no source shows nothing")
        XCTAssertTrue(central.connects.isEmpty, "nothing is swapped in for the watch")
        XCTAssertEqual(central.probes.count, 1)

        let activity = try await run.finish(in: ModelContext(container))
        XCTAssertEqual(activity.heartRateSource, "Health", "Health fills the summary after the run")
        XCTAssertEqual(history.calls.count, 1)
    }

    func testAutomaticTakesAnAddedStrapInRangeBeforeTheWatch() async throws {
        store(.automatic, devices: [polar])
        let watch = FakeWatch()
        let central = FakeCentral()
        central.nearby = [polar.id]
        let run = makeRun(central: central, watch: watch)
        XCTAssertTrue(run.start(.run))
        await run.awaitHeartRateSource()
        addTeardownBlock { @MainActor in run.cancel() }
        XCTAssertEqual(run.heartRate?.source, .device(polar.id, name: "Polar H10"))
        XCTAssertEqual(watch.starts, 0, "the watch is never asked when a strap was picked")
    }

    func testAutomaticTakesTheWatchWhenNoStrapIsInRange() async throws {
        store(.automatic)
        let watch = FakeWatch()
        let central = FakeCentral()
        let run = makeRun(central: central, watch: watch)
        XCTAssertTrue(run.start(.walk))
        await run.awaitHeartRateSource()
        addTeardownBlock { @MainActor in run.cancel() }
        XCTAssertEqual(run.heartRate?.source, .watch)
        XCTAssertEqual(watch.starts, 1)
        XCTAssertTrue(central.probes.isEmpty, "nothing added, so no Bluetooth look")
    }

    func testAWatchThatIsNotReadyIsNeverAsked() async throws {
        store(.watch)
        let watch = FakeWatch()
        let run = makeRun(watch: watch, ready: false)
        XCTAssertTrue(run.start(.run))
        await run.awaitHeartRateSource()
        addTeardownBlock { @MainActor in run.cancel() }
        XCTAssertNil(run.heartRate?.source)
        XCTAssertEqual(watch.starts, 0)
    }

    func testOffNeverAsksTheWatch() async throws {
        store(.off)
        let watch = FakeWatch()
        let run = makeRun(watch: watch)
        XCTAssertTrue(run.start(.run))
        await run.awaitHeartRateSource()
        addTeardownBlock { @MainActor in run.cancel() }
        XCTAssertEqual(watch.starts, 0)
        XCTAssertNil(run.liveHeartRate(now: .now))
    }

    /// A watch that stops sending is not swapped for a strap or Health: the
    /// number hides at ten seconds and comes back when readings resume.
    func testAQuietWatchIsNotSwappedForAStrap() async throws {
        store(.automatic, devices: [polar])
        let watch = FakeWatch()
        let central = FakeCentral()          // not in range for the 3 s look
        let run = makeRun(central: central, watch: watch)
        XCTAssertTrue(run.start(.run))
        await run.awaitHeartRateSource()
        addTeardownBlock { @MainActor in run.cancel() }
        let session = try XCTUnwrap(run.heartRate)
        XCTAssertEqual(session.source, .watch)

        let t0 = Date(timeIntervalSince1970: 1_900_000_000)
        watch.deliver(140, at: t0)
        XCTAssertEqual(run.liveHeartRate(now: t0.addingTimeInterval(5))?.number, "140 bpm")
        XCTAssertEqual(run.liveHeartRate(now: t0.addingTimeInterval(11))?.number, "—")

        central.nearby = [polar.id]          // the strap turns up while the watch is quiet
        watch.deliver(146, at: t0.addingTimeInterval(30))
        XCTAssertEqual(run.liveHeartRate(now: t0.addingTimeInterval(31))?.number, "146 bpm")
        XCTAssertEqual(run.liveHeartRate(now: t0.addingTimeInterval(31))?.source, "from Apple Watch")

        XCTAssertTrue(run.heartRate === session)
        XCTAssertEqual(session.readings, [140, 146])
        XCTAssertTrue(central.connects.isEmpty, "never a strap mid-run")
        XCTAssertEqual(central.probes.count, 1, "and never looked again")
        XCTAssertEqual(watch.starts, 1, "asked once")
    }

    func testCancelEndsTheWatchAndALateReadingIsDropped() async throws {
        store(.watch)
        let watch = FakeWatch()
        let run = makeRun(watch: watch)
        XCTAssertTrue(run.start(.run))
        await run.awaitHeartRateSource()
        let session = try XCTUnwrap(run.heartRate)
        let callback = try XCTUnwrap(watch.onReading)

        run.cancel()
        XCTAssertEqual(watch.effectiveStops, 1)
        callback(150, .now)
        XCTAssertTrue(session.readings.isEmpty, "an ended session takes nothing")
    }

    /// The watch's answer arrives after the run ended: it is let go, and
    /// nothing is wired to a run that is over.
    func testAStartThatAnswersAfterCancelIsStopped() async throws {
        store(.watch)
        let watch = FakeWatch()
        watch.holdsStart = true
        let run = makeRun(watch: watch)
        XCTAssertTrue(run.start(.run))
        for _ in 0..<200 where watch.starts == 0 { await Task.yield() }
        XCTAssertEqual(watch.starts, 1)

        run.cancel()
        let stopsAtCancel = watch.stops
        watch.releaseStart()
        await run.awaitHeartRateSource()
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(watch.stops, stopsAtCancel + 1, "the late start is let go")
        XCTAssertNil(watch.onReading)
        XCTAssertNil(run.heartRate)
    }

    /// Finish never waits on a watch that has not answered.
    func testFinishDoesNotWaitOnTheWatch() async throws {
        store(.watch)
        let watch = FakeWatch()
        watch.holdsStart = true
        let history = FakeHistory([100, 120])
        let run = makeRun(history: history, watch: watch)
        XCTAssertTrue(run.start(.run))
        for _ in 0..<200 where watch.starts == 0 { await Task.yield() }

        let activity = try await run.finish(in: ModelContext(container))
        XCTAssertEqual(activity.heartRateSource, "Health")
        watch.releaseStart()
        await run.awaitHeartRateSource()
        XCTAssertNil(watch.onReading, "nothing wired to a finished run")
        XCTAssertGreaterThanOrEqual(watch.stops, 1)
    }

    /// The watch holds its callback for the length of the run; it must not hold
    /// the run's owner.
    func testTheWatchCallbackDoesNotRetainTheRun() async throws {
        store(.watch)
        let watch = FakeWatch()
        var run: ActiveRun? = makeRun(watch: watch)
        XCTAssertTrue(run?.start(.run) ?? false)
        await run?.awaitHeartRateSource()
        XCTAssertNotNil(watch.onReading)
        weak var weakRun = run
        weak var weakSession = run?.heartRate
        run?.recording?.handle(.cancel)   // stops the tracker without ending through the link
        run = nil
        XCTAssertNil(weakRun, "the callback holds the session weakly, never the run")
        XCTAssertNil(weakSession)
        watch.deliver(150, at: .now)       // and a reading for nobody is harmless
    }

    /// Run A's watch start answers after A was cancelled and run B began: it is
    /// let go without stopping B's watch, and B keeps its readings.
    func testALateStartFromAnEarlierRunDoesNotStopTheNextRunsWatch() async throws {
        store(.watch)
        let watch = FakeWatch()
        watch.holdsStart = true
        let run = makeRun(watch: watch)
        XCTAssertTrue(run.start(.run))
        for _ in 0..<200 where watch.starts == 0 { await Task.yield() }
        run.cancel()

        watch.holdsStart = false
        XCTAssertTrue(run.start(.run))
        await run.awaitHeartRateSource()
        addTeardownBlock { @MainActor in run.cancel() }
        XCTAssertEqual(watch.starts, 2)
        let runB = try XCTUnwrap(watch.startedRuns.last)
        XCTAssertEqual(run.heartRate?.source, .watch)
        let effective = watch.effectiveStops

        watch.releaseStart()             // A's start answers now
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(watch.effectiveStops, effective, "A's late stop is a no-op")
        XCTAssertEqual(watch.current, runB)
        XCTAssertNotNil(watch.onReading, "B's callback stays")
        let at = Date.now
        watch.deliver(150, at: at)
        XCTAssertEqual(run.liveHeartRate(now: at)?.number, "150 bpm")
    }

    /// A watch that never launched leaves no "Apple Watch" on the card.
    func testAWatchThatNeverLaunchedShowsNoSource() async throws {
        store(.watch)
        let watch = FakeWatch()
        watch.failsToStart = true
        let history = FakeHistory([118, 122])
        let run = makeRun(history: history, watch: watch)
        XCTAssertTrue(run.start(.run))
        await run.awaitHeartRateSource()
        XCTAssertNil(run.liveHeartRate(now: .now))
        XCTAssertNil(watch.current)
        let activity = try await run.finish(in: ModelContext(container))
        XCTAssertEqual(activity.heartRateSource, "Health")
    }
}
