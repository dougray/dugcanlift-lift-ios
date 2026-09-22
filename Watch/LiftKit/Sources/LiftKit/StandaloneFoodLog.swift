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

/// Export's empty state. Since 2026-09-13 an empty export really does mean an
/// empty log — age hides nothing — so the only case left to distinguish is a
/// food logged without macros, which cannot be encoded yet.
///
/// Kept beside the store rather than in the view so it can be tested, and
/// worded to match Wear's `exportEmptyMessage`.
public func exportEmptyMessage(skippedCount: Int) -> String {
    guard skippedCount > 0 else { return "Nothing logged yet." }
    let entryWord = skippedCount == 1 ? "entry" : "entries"
    return "\(skippedCount) \(entryWord) can't be exported yet. Update LIFT on your iPhone."
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
///
/// **Nothing here deletes data it does not understand.** Until a code is
/// scanned, this store is the only copy of the log that exists anywhere, so an
/// overwrite is permanent. Two rules follow from that, and both were defects
/// once (issue #4):
///
/// - Retention is bounded by **count only**. Nothing is deleted or hidden
///   because of a date — a watch that came back from a flat battery believing
///   it was 2016 used to erase everything it had logged while confused, the
///   first time it logged anything after the clock corrected itself. There is
///   no longer any code path that reads the clock to decide what a user may
///   see or export, which is the strongest form of that guarantee.
///   (Settled 2026-09-13: a watch out of contact for two months still hands
///   over everything it recorded, rather than the window quietly stranding it.)
/// - Decoding is **per entry**. An entry this build cannot read is carried
///   forward verbatim and retried on every load, rather than taken as proof
///   the whole log is gone. The previous all-or-nothing `try?` turned any
///   schema change into a silent wipe of every entry the user had.
public final class StandaloneFoodLog {

    private let defaults: UserDefaults
    private let key = "com.dugcanlift.lift.standaloneFoodLog"
    private let skippedCountKey = "com.dugcanlift.lift.standaloneFoodLog.skippedCount"
    /// Where a blob that could not be parsed at all is set aside, so that
    /// replacing it is never the same thing as destroying it.
    private let quarantineKey = "com.dugcanlift.lift.standaloneFoodLog.unreadable"
    private let maxEntries: Int

    /// Bound on the carried-forward shadow list, matching `maxEntries`: it
    /// should never hold more dead weight than the live log itself could.
    private var maxUnreadableEntries: Int { maxEntries }

    public init(defaults: UserDefaults = .standard,
                maxEntries: Int = 200) {
        self.defaults = defaults
        self.maxEntries = maxEntries
    }

    /// Everything storage holds, oldest first — the order the export encodes.
    /// No age filter: if it is retained, it is exportable.
    public var entries: [LoggedFood] {
        load().entries.sorted { $0.loggedAt < $1.loggedAt }
    }

    /// Entries this build could not decode, kept verbatim against a later one.
    public var unreadableCount: Int { load().unreadable.count }

    public func append(_ entry: LoggedFood) {
        var stored = load()
        stored.entries = cappedByCount(stored.entries + [entry])
        write(stored)
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
        defaults.removeObject(forKey: quarantineKey)
    }

    /// Removes exactly `entriesToRemove`, leaving everything else -- in
    /// particular anything appended since they were captured -- intact.
    /// `ExportFoodsView` uses this instead of `clear()` so its confirm
    /// action deletes only the entries it actually encoded and displayed,
    /// not whatever the log happens to hold at confirm time.
    /// Removes one stored entry per element of `entriesToRemove`, not every
    /// entry that happens to equal one.
    ///
    /// The distinction is not academic here: `LoggedFood` is a value type
    /// with no identity, so logging 50 g of the same food twice in the same
    /// second produces two entries that compare equal. A set-membership
    /// filter would delete both when asked to delete one, silently
    /// destroying a log entry the user never exported — the exact failure
    /// this whole store exists to prevent.
    ///
    /// Pass entries obtained from `entries`, not ones you built yourself:
    /// `Date` loses sub-second precision through the JSON round trip, so a
    /// `LoggedFood` constructed in memory never compares equal to the one
    /// that comes back out. `ExportFoodsView` captures `foodLog.entries` for
    /// exactly this reason.
    public func remove(_ entriesToRemove: [LoggedFood]) {
        guard !entriesToRemove.isEmpty else { return }

        var remaining: [LoggedFood: Int] = [:]
        for entry in entriesToRemove {
            remaining[entry, default: 0] += 1
        }

        var stored = load()
        stored.entries = stored.entries.sorted { $0.loggedAt < $1.loggedAt }.filter { entry in
            guard let count = remaining[entry], count > 0 else { return true }
            remaining[entry] = count - 1
            return false
        }
        write(stored)
    }

    /// The only rule that may drop a live entry: 200 of them, oldest first.
    /// Deliberately not a date — see the note on the type.
    private func cappedByCount(_ all: [LoggedFood]) -> [LoggedFood] {
        let sorted = all.sorted { $0.loggedAt < $1.loggedAt }
        return sorted.count > maxEntries ? Array(sorted.suffix(maxEntries)) : sorted
    }

    /// What one load recovered: the entries this build understands, plus the
    /// raw JSON of the ones it does not.
    private struct StoredLog {
        var entries: [LoggedFood] = []
        var unreadable: [Any] = []
        var unreadableDropped: Int = 0
    }

    /// Reads storage without ever concluding, from a failure, that there was
    /// nothing there. Accepts both shapes: the bare array the previous build
    /// wrote, and the object this one writes.
    private func load() -> StoredLog {
        guard let data = defaults.data(forKey: key) else { return StoredLog() }
        guard let root = try? JSONSerialization.jsonObject(with: data) else {
            // Not JSON at all. Set it aside so that whatever replaces it is not
            // also the thing that destroyed it.
            quarantine(data)
            return StoredLog()
        }

        let rawEntries: [Any]
        var carried: [Any] = []
        var dropped = 0

        if let array = root as? [Any] {
            rawEntries = array                                   // legacy format
        } else if let object = root as? [String: Any] {
            rawEntries = object["entries"] as? [Any] ?? []
            carried = object["unreadable"] as? [Any] ?? []
            dropped = object["unreadableDropped"] as? Int ?? 0
        } else {
            quarantine(data)
            return StoredLog()
        }

        var log = StoredLog(entries: [], unreadable: [], unreadableDropped: dropped)

        // Carried-forward entries are retried first: a build that understands
        // the shape again gets the data back rather than a permanent tombstone.
        for element in carried + rawEntries {
            if let decoded = decodeEntry(element) {
                log.entries.append(decoded)
            } else {
                log.unreadable.append(element)
            }
        }
        return log
    }

    private func decodeEntry(_ element: Any) -> LoggedFood? {
        guard JSONSerialization.isValidJSONObject([element]),
              let data = try? JSONSerialization.data(withJSONObject: element) else { return nil }
        return try? SyncEnvelope.decoder.decode(LoggedFood.self, from: data)
    }

    private func quarantine(_ data: Data) {
        // First one wins: a later unreadable blob must not overwrite the
        // original evidence.
        guard defaults.data(forKey: quarantineKey) == nil else { return }
        defaults.set(data, forKey: quarantineKey)
    }

    private func write(_ log: StoredLog) {
        guard let encoded = try? SyncEnvelope.encoder.encode(cappedByCount(log.entries)),
              let entryObjects = try? JSONSerialization.jsonObject(with: encoded) else { return }

        var unreadable = log.unreadable
        var dropped = log.unreadableDropped
        if unreadable.count > maxUnreadableEntries {
            dropped += unreadable.count - maxUnreadableEntries
            unreadable = Array(unreadable.suffix(maxUnreadableEntries))
        }

        let payload: [String: Any] = [
            "entries": entryObjects,
            "unreadable": unreadable,
            "unreadableDropped": dropped
        ]
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        defaults.set(data, forKey: key)
    }
}
