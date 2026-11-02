import Foundation

// Heart rate per set: the highest heart rate the watch measured around each
// set, shown beside the set and never graded (LIFT superproject,
// `docs/superpowers/plans/2026-10-28-build-plan.md`, item 16).
//
// One pure function with no sensor and no view in it, for the reason
// `GuidedSession` is a value: this decides a number somebody reads about
// their own body, and a rule inside a HealthKit callback cannot be tested.
// `SetHeartRateTests` checks it against `heart-rate-per-set.json`, a fixture
// worked by hand and checked into this repo and `dugcanlift-lift-watch`,
// whose Kotlin port checks the same file. Never regenerate it from either
// port: if this disagrees with it, this is wrong.

/// One heart-rate reading: when it was measured and the beats per minute.
public struct HeartRateSample: Equatable, Sendable {
    public var date: Date
    public var bpm: Double

    public init(date: Date, bpm: Double) {
        self.date = date
        self.bpm = bpm
    }
}

public enum SetHeartRate {

    /// A set as the rule sees it: its id, its tick (`completedAt`), and the
    /// duration a timed set states, if any.
    public struct Tick<ID: Hashable>: Equatable {
        public var id: ID
        public var tick: Date?
        public var durationSec: Int?

        public init(id: ID, tick: Date?, durationSec: Int? = nil) {
            self.id = id
            self.tick = tick
            self.durationSec = durationSec
        }
    }

    /// How long after the tick a window stays open. Heart rate keeps rising
    /// for a few seconds after the bar is racked, and an optical sensor lags;
    /// 20 seconds catches that without reaching into the rest.
    public static let afterTick: TimeInterval = 20
    /// How far before the tick a window may reach, so a walk before the first
    /// set does not hand that set a figure.
    public static let lookback: TimeInterval = 300
    /// Added to a timed set's own duration when that reaches further back.
    public static let durationAllowance: TimeInterval = 30

    /// The window each ticked set's figure is read from, both ends inclusive.
    ///
    /// Ticked sets are taken in tick order, whatever exercise they belong to
    /// and whatever order they are listed in. A window ends 20 seconds after
    /// its tick, or at the next tick if that is sooner, and starts at the
    /// previous tick, or at `sessionStart` for the first set -- but never
    /// earlier than the lookback. A set with no tick has no window and is not
    /// anybody's neighbour.
    public static func windows<ID: Hashable>(sessionStart: Date,
                                             sets: [Tick<ID>]) -> [ID: ClosedRange<Date>] {
        let ticked = sets.compactMap { set in set.tick.map { (set, $0) } }
            .enumerated()
            // Stable for two sets ticked at the same moment.
            .sorted { $0.element.1 == $1.element.1 ? $0.offset < $1.offset : $0.element.1 < $1.element.1 }
            .map(\.element)

        var windows: [ID: ClosedRange<Date>] = [:]
        for (index, (set, tick)) in ticked.enumerated() {
            let reach = max(lookback, set.durationSec.map { TimeInterval($0) + durationAllowance } ?? 0)
            let previous = index > 0 ? ticked[index - 1].1 : sessionStart
            let start = max(previous, tick.addingTimeInterval(-reach))
            var end = tick.addingTimeInterval(afterTick)
            if index + 1 < ticked.count { end = min(end, ticked[index + 1].1) }
            guard start <= end else { continue }
            windows[set.id] = start...end
        }
        return windows
    }

    /// The highest reading in a window, in whole beats per minute, halves
    /// away from zero. A sample of zero or below is not a reading. A window
    /// with no reading is `nil`: never a zero, never a neighbour's figure,
    /// never interpolated.
    public static func maxBpm(in window: ClosedRange<Date>,
                              samples: [HeartRateSample]) -> Int? {
        let highest = samples
            .filter { $0.bpm > 0 && $0.bpm.isFinite && window.contains($0.date) }
            .map(\.bpm)
            .max()
        guard let highest else { return nil }
        return Int(highest.rounded(.toNearestOrAwayFromZero))
    }

    /// Every ticked set's figure. A set with no reading in its window is
    /// absent from the result, exactly as a set with no tick is.
    public static func figures<ID: Hashable>(sessionStart: Date,
                                             samples: [HeartRateSample],
                                             sets: [Tick<ID>]) -> [ID: Int] {
        windows(sessionStart: sessionStart, sets: sets).compactMapValues {
            maxBpm(in: $0, samples: samples)
        }
    }
}

// MARK: - On the watch's own draft

extension WorkoutDraft {

    /// The figures to write now: every set whose window has closed by `now`
    /// -- 20 seconds after its tick, or at the next tick -- or, when
    /// `finishing`, every set whose window is still open too. Only figures
    /// that would change the draft are returned.
    ///
    /// **A figure only ever rises.** Samples arrive late and in batches, so a
    /// set is read again whenever more of them land, and the buffer the
    /// watch holds them in forgets the oldest; a later read can therefore
    /// see more of a window than an earlier one, or less. The higher figure
    /// is the one taken from the most readings, and every figure ever
    /// computed was a real reading inside that set's window, so the higher
    /// one is kept and a read that found less is not written.
    public func heartRateUpdates(samples: [HeartRateSample], now: Date,
                                 finishing: Bool = false) -> [UUID: Int] {
        let sets = exercises.flatMap(\.sets)
        let windows = SetHeartRate.windows(
            sessionStart: startedAt,
            sets: sets.map { SetHeartRate.Tick(id: $0.id, tick: $0.completedAt) }
        )
        var updates: [UUID: Int] = [:]
        for set in sets {
            guard let window = windows[set.id], finishing || window.upperBound <= now,
                  let figure = SetHeartRate.maxBpm(in: window, samples: samples),
                  figure > (set.maxBpm ?? 0) else { continue }
            updates[set.id] = figure
        }
        return updates
    }
}
