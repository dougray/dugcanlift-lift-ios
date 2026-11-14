import Foundation
import Observation
import SwiftData

/// The one run in progress, and whether its full screen is showing.
///
/// A run used to belong to the cover that presented it, so leaving the screen
/// ended the run. It belongs here instead, to the app: the screen is a view of
/// the run and can be closed and reopened, and the Train card shows the run
/// live while the screen is away. The run ends only on Cancel or Finish --
/// leaving the screen, switching tabs, a light/dark switch and backgrounding
/// stop nothing.
///
/// One run at a time: `start` refuses while one is recording.
///
/// Finish waits on Apple Health when no strap spoke, so it is async. While it
/// waits the run is *finishing*: a second Finish is refused (`notRecording`),
/// a new run cannot start, and a Cancel in that window wins -- the run is
/// discarded whole and the waiting Finish saves nothing. The run is saved
/// exactly once or not at all, and a failed save leaves it recording.
@MainActor
@Observable
final class ActiveRun {
    enum FinishError: Error { case notRecording }

    private(set) var recording: OutdoorRecording?
    /// Whether the full recording screen is up. The run goes on either way.
    var isScreenShown = false
    /// The run just saved, for the review screen. Whichever view finished it
    /// -- the full screen or the card -- it is presented from one place, because
    /// the view that finished it is gone by the time the review shows.
    var justFinished: OutdoorActivity?

    /// This run's heart rate, once its one source has been picked (three
    /// seconds at most after Start), and nil before that. Its source never
    /// changes: a strap that drops is reconnected by the radio, never replaced.
    private(set) var heartRate: RunHeartRateSession?

    /// The run whose Finish is waiting on Health, if any. A run, not a flag,
    /// so a cancelled run's late Finish cannot be mistaken for the next run's.
    private var finishing: OutdoorRecording?
    var isFinishing: Bool { finishing != nil }

    private let history: HeartRateHistory
    let central: HeartRateConnecting
    let watch: WatchHeartRateLinking
    private let watchAvailability: WatchAvailability
    private let defaults: UserDefaults
    private let save: @MainActor (ModelContext) throws -> Void
    private var heartRateSetting: HeartRateSetting = .automatic
    @ObservationIgnored private var picking: Task<Void, Never>?
    /// This run's name to the watch, so a late answer from an earlier run can
    /// never start or stop the watch for this one.
    @ObservationIgnored private var watchRun: UUID?

    init(history: HeartRateHistory = HealthKitManager.shared,
         central: HeartRateConnecting? = nil,
         watch: WatchHeartRateLinking? = nil,
         watchAvailability: WatchAvailability? = nil,
         defaults: UserDefaults = .standard,
         save: @escaping @MainActor (ModelContext) throws -> Void = { try $0.save() }) {
        self.history = history
        self.central = central ?? HeartRateCentral.shared
        self.watch = watch ?? WatchHeartRateLink.shared
        self.watchAvailability = watchAvailability ?? PairedWatchAvailability()
        self.defaults = defaults
        self.save = save
    }

    /// Begins a run and shows its screen. False, and nothing changes, while
    /// one is already recording.
    @discardableResult
    func start(_ type: OutdoorActivityType) -> Bool {
        guard recording == nil else { return false }
        let new = OutdoorRecording(activityType: type)
        recording = new
        // Tracking begins here, not when the screen appears: if SwiftUI never
        // shows the presentation (a tap during the last cover's dismissal, or
        // another presentation up), a run must not sit "recording" with a
        // tracker that is not running. The screen's own appear is then a no-op.
        new.handle(.appear)
        isScreenShown = true
        beginHeartRate(for: new)
        return true
    }

    /// Picks the run's one source, once, and starts listening to it.
    ///
    /// The setting and the added devices are read now and held for the run.
    /// Only the person's own added devices are ever looked for (and only when
    /// there is one to look for, so a phone with none never raises the
    /// Bluetooth prompt); the picker chooses among those in range after a
    /// three second look; and only its answer is connected. A strap that
    /// appears after the look is not used live -- Health fills the summary
    /// after the run -- and nothing re-picks when a reading goes quiet.
    ///
    /// LIFT on the Apple Watch is picked only when it is ready (paired, LIFT
    /// installed: `WatchAvailability`, read once now), and asked to start once.
    /// If it cannot be asked the run has no live source, and Health fills the
    /// summary after it.
    private func beginHeartRate(for run: OutdoorRecording) {
        let setting = HeartRateStorage.setting(from: defaults.string(forKey: HeartRateStorage.settingKey) ?? "")
        let added = HeartRateStorage.devices(from: defaults.string(forKey: HeartRateStorage.devicesKey) ?? "")
        heartRateSetting = setting
        heartRate = nil
        // Read once, now, like the setting: a watch paired mid-run changes nothing.
        let watchAvailable = setting == .off ? false : watchAvailability.isWatchAppReady
        let watchRun = UUID()
        self.watchRun = watchRun
        picking = Task { [weak self] in
            guard let self else { return }
            var inRange: [AddedHeartRateDevice] = []
            switch setting {
            case .automatic, .device:
                if !added.isEmpty { inRange = await central.inRange(added, within: .seconds(3)) }
            case .watch, .off:
                break
            }
            // Over, replaced, or being finished while it looked: connect to
            // nothing. A strap picked now would be released by `end()` a moment
            // later, after Finish has already decided from Health.
            guard !Task.isCancelled, recording === run, finishing !== run else { return }
            var source = HeartRateSourcePicker.pick(setting, addedInRange: inRange, watchAvailable: watchAvailable)
            if source == .watch {
                // A watch that cannot be asked is no live source -- never a
                // strap or Health in its place -- and Finish is never held up:
                // Health fills the summary after the run.
                let started: Bool
                do { try await watch.start(run: watchRun); started = true } catch { started = false }
                source = WatchLinkStart.source(started: started)
                guard !Task.isCancelled, recording === run, finishing !== run else {
                    // Asked, and the run ended or began finishing meanwhile:
                    // let the watch go rather than leave it measuring.
                    if started { watch.stop(run: watchRun) }
                    return
                }
            }
            let session = RunHeartRateSession(begin: source)
            heartRate = session
            if case .device(let id, _)? = source {
                // Weak, and the session only: the radio holds this callback for
                // the length of the run and must not hold the run's owner. The
                // radio calls it on the main actor.
                central.connect(id, allowed: added) { [weak session] bpm, at in
                    session?.receive(bpm, at: at)
                }
            } else if source == .watch {
                // The same rule as the strap's: weak, the session only, on the
                // main actor (the link hops there). A watch that goes quiet
                // hides the number at ten seconds and nothing is swapped in.
                watch.onReading = { [weak session] bpm, at in
                    session?.receive(bpm, at: at)
                }
            }
        }
    }

    /// Returns once the source has been picked (or the run ended first).
    func awaitHeartRateSource() async {
        await picking?.value
    }

    /// The live card's heart rate: the number, or a dash once the last reading
    /// is more than ten seconds old, with the source under it. Nil when this
    /// run has no source, which shows nothing. Takes `now`, so a view that
    /// ticks each second hides the number on time with nothing else changing.
    func liveHeartRate(now: Date) -> LiveHeartRateLine? {
        guard let session = heartRate, let source = session.source else { return nil }
        return LiveHeartRateLine(number: RunHeartRateWords.live(session.shown(now: now)),
                                 source: RunHeartRateWords.source(source.storedName))
    }

    /// Brings the full screen back.
    func open() {
        guard recording != nil else { return }
        if isScreenShown {
            // Open is only reachable while the screen is not up, so a screen
            // already "shown" is a presentation SwiftUI dropped. Down and up
            // again, a turn apart, is a fresh presentation.
            isScreenShown = false
            Task { @MainActor in
                if self.recording != nil { self.isScreenShown = true }
            }
        } else {
            isScreenShown = true
        }
    }

    /// The person closed the screen. The run continues.
    func close() {
        recording?.handle(.left)
        isScreenShown = false
    }

    /// Throws the run away.
    func cancel() {
        recording?.handle(.cancel)
        end()
    }

    /// Saves the run and ends it. A failed save throws and keeps recording, so
    /// nothing walked after it is lost; the unsaved insert is backed out so a
    /// retry cannot save two copies. The screen and the card both come here.
    ///
    /// The run ends at the moment Finish is chosen: its route, its end time and
    /// the heart rate window are taken then, before Health is asked. While
    /// Health answers the run is finishing -- a second Finish throws
    /// `notRecording`, and a Cancel discards the run, in which case this
    /// throws `notRecording` too and saves nothing.
    func finish(in context: ModelContext) async throws -> OutdoorActivity {
        guard let run = recording, finishing !== run else { throw FinishError.notRecording }
        finishing = run
        defer { if finishing === run { finishing = nil } }

        let endedAt = Date.now
        let points = run.tracker.points
        // Not `end()`ed yet: if the save fails the run goes on, listening.
        let readings = heartRate?.readings ?? []
        let record = await RunHeartRateFinish.record(
            readings: readings, sourceName: heartRate?.source?.storedName,
            setting: heartRateSetting, history: history, from: run.startedAt, to: endedAt)
        // Cancelled while Health answered: the person's later word stands.
        guard recording === run else { throw FinishError.notRecording }

        let activity = OutdoorActivity(activityType: run.activityType, startedAt: run.startedAt)
        activity.endedAt = endedAt
        activity.routePoints = points
        activity.distanceMeters = OutdoorActivityMath.totalDistanceMeters(points)
        activity.elevationGainMeters = OutdoorActivityMath.elevationGainMeters(points)
        RunHeartRateFinish.apply(record, to: activity)
        context.insert(activity)
        do {
            try save(context)
        } catch {
            context.delete(activity)
            throw error
        }
        run.handle(.finish)
        end()
        justFinished = activity
        return activity
    }

    private func end() {
        picking?.cancel()
        picking = nil
        // Lets the strap or the watch go and ends the session, so a late
        // reading is dropped.
        central.disconnect()
        if let watchRun { watch.stop(run: watchRun) }
        watchRun = nil
        _ = heartRate?.end()
        heartRate = nil
        finishing = nil
        recording = nil
        isScreenShown = false
    }
}
