import Foundation

/// Edits made while the phone is out of range.
///
/// The watch is frequently the only device in the room, so an edit that cannot
/// be delivered is queued rather than dropped. Because the receiver reconciles
/// by revision, only the newest envelope per workout is worth keeping — an
/// intermediate revision would be discarded on arrival anyway.
public struct SyncOutbox: Equatable, Sendable {

    private var entries: [SyncEnvelope] = []

    public init(_ entries: [SyncEnvelope] = []) {
        for entry in entries { enqueue(entry) }
    }

    public var pending: [SyncEnvelope] { entries }

    public var isEmpty: Bool { entries.isEmpty }

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
    }

    /// Removes the queued entry for `workoutID` unconditionally, with no ack
    /// required. Meant for one-shot requests (e.g. a `.foodLogged` envelope)
    /// where there is nothing for the counterpart to reconcile a revision
    /// against, unlike a workout edit, which must stay queued until it is
    /// genuinely acknowledged.
    public mutating func remove(workoutID: UUID) {
        entries.removeAll { $0.workoutID == workoutID }
    }

    /// Hands over everything pending, oldest first, and clears the queue.
    public mutating func drain() -> [SyncEnvelope] {
        let drained = entries.sorted { $0.revision < $1.revision }
        entries.removeAll()
        return drained
    }
}
