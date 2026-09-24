import Foundation
import LiftSync

/// Edits made while the phone is out of range.
///
/// The watch is frequently the only device in the room, so an edit that cannot
/// be delivered is queued rather than dropped. Because the receiver reconciles
/// by revision, only the newest envelope per workout is worth keeping — an
/// intermediate revision would be discarded on arrival anyway.
///
/// An entry stays pending until the phone acknowledges its revision, but it
/// is handed to the transport **once** per revision (`unsent`,
/// `markHandedOver`). The transport is `transferUserInfo`, whose OS queue
/// keeps an envelope across suspension and termination on its own, so
/// handing the same revision over again only queues a duplicate. The phone
/// acknowledges nothing but foods, so every flush — every set logged, every
/// food, every reachability change — used to queue every pending envelope
/// again, a finished session and a finished run included, for as long as
/// the app lived.
public struct SyncOutbox: Equatable, Sendable {

    private var entries: [SyncEnvelope] = []
    /// What has already been handed over, by workout id: the revision and
    /// event of that handover. A newer revision, or a different event at the
    /// same revision (`WORKOUT_EDITED` then `SESSION_FINISHED`), is new.
    private var handedOver: [UUID: HandedOver] = [:]

    private struct HandedOver: Equatable, Sendable {
        var revision: Int
        var event: SyncEnvelope.Event
    }

    public init(_ entries: [SyncEnvelope] = []) {
        for entry in entries { enqueue(entry) }
    }

    public var pending: [SyncEnvelope] { entries }

    public var isEmpty: Bool { entries.isEmpty }

    /// The pending envelopes not yet handed to the transport, oldest first.
    public var unsent: [SyncEnvelope] {
        entries.filter { entry in
            guard let sent = handedOver[entry.workoutID] else { return true }
            return sent.revision != entry.revision || sent.event != entry.event
        }
    }

    /// Records that `envelope` has been handed to the transport. It stays
    /// pending — only an acknowledgement clears it — but is not handed over
    /// again unless a newer revision replaces it.
    public mutating func markHandedOver(_ envelope: SyncEnvelope) {
        handedOver[envelope.workoutID] = HandedOver(revision: envelope.revision, event: envelope.event)
    }

    /// The transport reported that handing `envelope` over failed (a
    /// `transferUserInfo` that finished with an error), so the next flush
    /// hands it over again. Nothing changes if a newer revision has been
    /// handed over since.
    public mutating func handoverFailed(_ envelope: SyncEnvelope) {
        guard handedOver[envelope.workoutID] == HandedOver(revision: envelope.revision,
                                                           event: envelope.event) else { return }
        handedOver[envelope.workoutID] = nil
    }

    public mutating func enqueue(_ envelope: SyncEnvelope) {
        if let index = entries.firstIndex(where: { $0.workoutID == envelope.workoutID }) {
            // Keep whichever revision is newer; a late enqueue of an older one
            // is the same stale-write problem the store guards against.
            if envelope.revision >= entries[index].revision {
                entries[index] = envelope
            }
            return
        }
        entries.append(envelope)
    }

    /// Removes the queued edit once the counterpart has acknowledged that
    /// revision or a later one. A stale ack leaves the entry queued.
    public mutating func acknowledge(_ ack: SyncEnvelope) {
        guard ack.event == .workoutSyncAck else { return }
        entries.removeAll { $0.workoutID == ack.workoutID && $0.revision <= ack.revision }
        if !entries.contains(where: { $0.workoutID == ack.workoutID }) {
            handedOver[ack.workoutID] = nil
        }
    }

    /// Removes the queued entry for `workoutID` unconditionally, with no ack
    /// required. Meant for one-shot requests (e.g. a `.foodLogged` envelope)
    /// where there is nothing for the counterpart to reconcile a revision
    /// against, unlike a workout edit, which must stay queued until it is
    /// genuinely acknowledged.
    public mutating func remove(workoutID: UUID) {
        entries.removeAll { $0.workoutID == workoutID }
        handedOver[workoutID] = nil
    }

    /// Hands over everything pending, oldest first, and clears the queue.
    public mutating func drain() -> [SyncEnvelope] {
        let drained = entries.sorted { $0.revision < $1.revision }
        entries.removeAll()
        handedOver.removeAll()
        return drained
    }
}
