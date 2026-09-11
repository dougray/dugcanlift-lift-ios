import Foundation

/// One food the user logged on the watch, complete enough to stand alone.
public struct LoggedFood: Codable, Equatable, Hashable, Sendable {
    public var food: WatchFood
    public var grams: Double
    public var meal: FoodLogMeal
    public var loggedAt: Date

    public init(food: WatchFood, grams: Double, meal: FoodLogMeal, loggedAt: Date) {
        self.food = food
        self.grams = grams
        self.meal = meal
        self.loggedAt = loggedAt
    }
}

/// Every food logged on this watch, retained until the user exports it.
///
/// Deliberately separate from `SyncOutbox`. That queue hands an envelope to
/// `transferUserInfo` and forgets it — correct when a phone exists, because
/// the OS delivers eventually. But `transferUserInfo` also returns normally
/// when **no iPhone has ever been paired**, and the watch cannot read back
/// from the OS queue, so a standalone watch retains nothing. This store is
/// what the export screen reads.
///
/// `UserDefaults`-backed, following `RecentFoodsSnapshotStore` — the repo's
/// only persistence pattern.
public final class StandaloneFoodLog {

    private let defaults: UserDefaults
    private let key = "com.dugcanlift.lift.standaloneFoodLog"
    private let skippedCountKey = "com.dugcanlift.lift.standaloneFoodLog.skippedCount"
    private let maxEntries: Int
    private let maxAgeDays: Int

    public init(defaults: UserDefaults = .standard,
                maxEntries: Int = 200,
                maxAgeDays: Int = 60) {
        self.defaults = defaults
        self.maxEntries = maxEntries
        self.maxAgeDays = maxAgeDays
    }

    /// Oldest first — the order the export encodes, and the order a reader
    /// would expect a log to arrive in.
    public var entries: [LoggedFood] {
        guard let data = defaults.data(forKey: key),
              let stored = try? SyncEnvelope.decoder.decode([LoggedFood].self, from: data)
        else { return [] }
        return stored.sorted { $0.loggedAt < $1.loggedAt }
    }

    public func append(_ entry: LoggedFood) {
        write(capped(entries + [entry]))
    }

    /// A food was logged whose macros are unknown (`RecentFoodsSnapshot.Item
    /// .watchFood` is nil), so it was dropped rather than appended here.
    /// Recorded so the export screen can tell the user "nothing exportable"
    /// apart from "nothing logged" -- see `ExportFoodsView`'s empty state.
    public var skippedCount: Int {
        defaults.integer(forKey: skippedCountKey)
    }

    public func recordSkipped() {
        defaults.set(skippedCount + 1, forKey: skippedCountKey)
    }

    public func clear() {
        defaults.removeObject(forKey: key)
        defaults.removeObject(forKey: skippedCountKey)
    }

    /// 200 entries or just under 60 days, whichever bites first, oldest
    /// dropped.
    ///
    /// "Just under": the cutoff is recomputed from `.now` on every call, so
    /// an entry logged exactly 60 days ago is already fractionally past the
    /// line by the time a later append re-evaluates it, and is dropped. Any
    /// implementation reading the clock at two different instants has that
    /// epsilon; it is named here so the boundary is not mistaken for a bug.
    ///
    /// Age uses `Calendar`, not `now - days * 86400`: seconds-based day
    /// arithmetic repeats a day across a DST fall-back, which would keep a
    /// 61-day-old entry alive for one extra day every autumn.
    private func capped(_ all: [LoggedFood]) -> [LoggedFood] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let cutoff = calendar.date(byAdding: .day, value: -maxAgeDays, to: .now)

        var kept = all.sorted { $0.loggedAt < $1.loggedAt }
        if let cutoff {
            kept = kept.filter { $0.loggedAt >= cutoff }
        }
        if kept.count > maxEntries {
            kept = Array(kept.suffix(maxEntries))
        }
        return kept
    }

    private func write(_ all: [LoggedFood]) {
        guard let data = try? SyncEnvelope.encoder.encode(all) else { return }
        defaults.set(data, forKey: key)
    }
}
