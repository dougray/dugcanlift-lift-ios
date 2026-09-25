import Foundation
import LiftSync

/// Every finished session this watch has not yet been told the phone has.
///
/// **Why this exists.** `WorkoutStore` and `SyncOutbox` are in memory: they
/// die with the app. A finished session used to live only in them and in
/// whatever `transferUserInfo` had queued at the OS level, which the app
/// cannot read back — so "did my workout reach my phone?" had no answer on
/// the watch, and the cases where it had not were exactly the cases nobody
/// could see. `transferUserInfo` also returns perfectly normally when **no
/// iPhone has ever been paired**, and when LIFT has been deleted from the
/// phone.
///
/// So a finished session is written here, durably, the moment it is
/// finished, and leaves only when the phone says it has stored it
/// (`WORKOUT_SYNC_ACK` under the session's id). On every launch and every
/// reachability change, whatever is still here is handed to the transport
/// again. Nothing on this watch ever deletes a session on the strength of
/// having *sent* it.
///
/// The rules are `StandaloneFoodLog`'s, for the reasons written out there,
/// and they were defects once:
///
/// - **Retention is bounded by count only.** Nothing is dropped because of
///   its date. A watch back from a flat battery believing it is 2016 must
///   not erase what it recorded while confused.
/// - **Decoding is per entry.** An envelope this build cannot read is
///   carried forward verbatim and retried on the next load, rather than
///   taken as proof the whole log is gone.
///
/// `UserDefaults`-backed, following `StandaloneFoodLog` and
/// `RecentFoodsSnapshotStore` — this package's only persistence pattern.
public final class UnsentSessionLog {

    private let defaults: UserDefaults
    private let key = "com.dugcanlift.lift.unsentSessions"
    private let maxEntries: Int

    /// 50 sessions is months of training for anyone, and the cap exists only
    /// so a watch that never meets a phone again cannot grow without bound.
    public init(defaults: UserDefaults = .standard, maxEntries: Int = 50) {
        self.defaults = defaults
        self.maxEntries = maxEntries
    }

    /// The `SESSION_FINISHED` envelopes still waiting, in the order they
    /// were recorded — except that an entry an earlier build could not read
    /// comes back at the front once one that can reads it, which costs
    /// nothing: the receiver reconciles each one on its own id.
    public var pending: [SyncEnvelope] {
        load().readable
    }

    /// How many entries this build could not decode. They are still stored,
    /// and a later build that understands them will send them.
    public var unreadableCount: Int { load().unreadable.count }

    public var isEmpty: Bool { pending.isEmpty && unreadableCount == 0 }

    /// Records a finished session, replacing any earlier revision of the
    /// same one: only the newest revision is worth keeping, because an
    /// intermediate one would be ignored on arrival anyway (the phone
    /// reconciles by revision). An *older* revision arriving here late
    /// changes nothing, which is the same stale-write guard `SyncOutbox`
    /// applies.
    public func record(_ envelope: SyncEnvelope) {
        guard envelope.event == .sessionFinished else { return }
        var stored = load()
        if let index = stored.readable.firstIndex(where: { $0.workoutID == envelope.workoutID }) {
            guard envelope.revision >= stored.readable[index].revision else { return }
            stored.readable[index] = envelope
        } else {
            stored.readable.append(envelope)
        }
        write(stored)
    }

    /// The phone has stored this session: it can go. An id this log does not
    /// hold — a food's acknowledgement, or a repeat of one already applied —
    /// changes nothing, and so does an acknowledgement of an older revision
    /// than the one waiting here, which would otherwise drop an edit the
    /// phone has not seen.
    @discardableResult
    public func acknowledge(_ ack: SyncEnvelope) -> Bool {
        guard ack.event == .workoutSyncAck else { return false }
        var stored = load()
        guard let index = stored.readable.firstIndex(where: {
            $0.workoutID == ack.workoutID && $0.revision <= ack.revision
        }) else { return false }
        stored.readable.remove(at: index)
        write(stored)
        return true
    }

    // MARK: - Storage

    private struct StoredLog {
        var readable: [SyncEnvelope] = []
        /// Raw JSON this build could not decode, kept verbatim and retried.
        var unreadable: [Any] = []
    }

    private func load() -> StoredLog {
        guard let data = defaults.data(forKey: key),
              let elements = try? JSONSerialization.jsonObject(with: data) as? [Any]
        else { return StoredLog() }

        var log = StoredLog()
        for element in elements {
            if let object = element as? [String: Any],
               let envelope = try? SyncEnvelope(messageBody: object) {
                log.readable.append(envelope)
            } else {
                log.unreadable.append(element)
            }
        }
        return log
    }

    private func write(_ log: StoredLog) {
        let objects = log.readable.compactMap { try? $0.messageBody() }
        // Each half is capped on its own, oldest first. Sharing one cap
        // would let entries this build cannot read crowd out the sessions it
        // can — or the reverse — and neither is a trade worth making when
        // both are somebody's training.
        let elements: [Any] = Array(log.unreadable.suffix(maxEntries))
            + Array(objects.suffix(maxEntries))
        guard JSONSerialization.isValidJSONObject(elements),
              let data = try? JSONSerialization.data(withJSONObject: elements) else { return }
        defaults.set(data, forKey: key)
    }
}
