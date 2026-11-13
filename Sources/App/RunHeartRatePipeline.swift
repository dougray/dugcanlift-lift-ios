import Foundation

// The path from a strap or Apple Health to the numbers a run keeps and shows.
//
// Tracked and shown, never targeted: no zones, colors, thresholds or advice.
// What a run keeps is its average, its max and the source's name; the readings
// themselves are never stored. Everything here is a value or a protocol, so it
// is tested without a radio or a Health store.

/// Heart rates Apple Health holds between two instants, in beats per minute,
/// oldest first. `HealthKitManager` is the real one; tests use a list.
protocol HeartRateHistory {
    func heartRates(from: Date, to: Date) async throws -> [Int]
}

/// The radio, as `ActiveRun` uses it. `HeartRateCentral` is the real one.
@MainActor
protocol HeartRateConnecting: AnyObject {
    func inRange(_ added: [AddedHeartRateDevice], within: Duration) async -> [AddedHeartRateDevice]
    func connect(_ id: UUID, allowed: [AddedHeartRateDevice]?, onReading: @escaping @MainActor (Int, Date) -> Void)
    func disconnect()
}

extension HeartRateCentral: HeartRateConnecting {}

extension LiveHeartRateSource {
    /// The name a run stores beside its figures.
    var storedName: String {
        switch self {
        case .device(_, let name): name
        case .watch: RunHeartRateFinish.watchSource
        }
    }
}

/// What a run keeps.
struct RunHeartRateRecord: Equatable {
    var averageBpm: Int
    var maxBpm: Int
    var source: String
}

enum RunHeartRateFinish {
    /// The source stored when Health, not a strap or the watch, supplied the figures.
    static let healthSource = "Health"
    /// The source stored for a run the watch measured (path B).
    static let watchSource = "Apple Watch"
    /// A summary opened within this long of the run's end asks Health again if
    /// it has no heart rate yet: a watch syncs to Health some time after a run.
    /// Older than this, the answer is whatever it was.
    static let requeryWindow: TimeInterval = 7 * 24 * 60 * 60

    /// What a run keeps once it ends.
    ///
    /// Live readings win, with the source's name, and Health is never asked.
    /// With none, and the setting not Off, Health is asked once for the run's
    /// own window and the figures are stored as source `Health`. A Health
    /// failure is no figures, not a failed run: the review asks again later.
    static func record(
        readings: [Int],
        sourceName: String?,
        setting: HeartRateSetting,
        history: HeartRateHistory,
        from start: Date,
        to end: Date
    ) async -> RunHeartRateRecord? {
        guard setting != .off else { return nil }
        if let live = RunHeartRateSummary.of(readings), let sourceName {
            return RunHeartRateRecord(averageBpm: live.averageBpm, maxBpm: live.maxBpm, source: sourceName)
        }
        return await fromHealth(history, from: start, to: end)
    }

    static func fromHealth(_ history: HeartRateHistory, from start: Date, to end: Date) async -> RunHeartRateRecord? {
        guard let rates = try? await history.heartRates(from: start, to: end),
              let summary = RunHeartRateSummary.of(rates.filter { $0 > 0 }) else { return nil }
        return RunHeartRateRecord(averageBpm: summary.averageBpm, maxBpm: summary.maxBpm, source: healthSource)
    }

    /// Whether a saved run should ask Health again: it ended, it has no heart
    /// rate, the setting is not Off, and it ended less than seven days ago.
    static func shouldRequery(endedAt: Date?, hasFigures: Bool, setting: HeartRateSetting, now: Date) -> Bool {
        guard setting != .off, !hasFigures, let endedAt else { return false }
        let age = now.timeIntervalSince(endedAt)
        return age < requeryWindow
    }

    /// Fills a saved run's heart rate from Health when `shouldRequery` says to.
    /// True when it changed the run; the caller saves.
    @discardableResult
    static func fill(_ activity: OutdoorActivity, setting: HeartRateSetting,
                     history: HeartRateHistory, now: Date = .now) async -> Bool {
        guard let endedAt = activity.endedAt,
              shouldRequery(endedAt: endedAt, hasFigures: activity.averageBpm != nil || activity.maxBpm != nil,
                            setting: setting, now: now),
              let record = await fromHealth(history, from: activity.startedAt, to: endedAt) else { return false }
        apply(record, to: activity)
        return true
    }

    static func apply(_ record: RunHeartRateRecord?, to activity: OutdoorActivity) {
        guard let record else { return }
        activity.averageBpm = record.averageBpm
        activity.maxBpm = record.maxBpm
        activity.heartRateSource = record.source
    }
}

/// What the live card shows: the number (or a dash once it is stale or before
/// the first reading) and the small line under it.
struct LiveHeartRateLine: Equatable {
    var number: String
    var source: String
}

/// The words, verbatim: `142 bpm` with `from Polar H10` under it while
/// running, `Avg 141 · Max 168 bpm` with the same source line after.
enum RunHeartRateWords {
    static func live(_ bpm: Int?) -> String {
        bpm.map { "\($0) bpm" } ?? "—"
    }

    static func source(_ name: String) -> String {
        name == RunHeartRateFinish.healthSource ? "from Health, after the run" : "from \(name)"
    }

    /// nil unless both figures exist and are real: blank is never a zero.
    static func summary(average: Int?, max: Int?) -> String? {
        guard let average, let max, average > 0, max > 0 else { return nil }
        return "Avg \(average) · Max \(max) bpm"
    }

    static func line(for activity: OutdoorActivity) -> (summary: String, source: String?)? {
        guard let summary = summary(average: activity.averageBpm, max: activity.maxBpm) else { return nil }
        return (summary, activity.heartRateSource.map(source))
    }
}
