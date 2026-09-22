import Foundation

/// The outcome of applying an inbound snapshot, per `docs/ARCHITECTURE.md`.
public enum ReconcileOutcome: Equatable, Sendable {
    /// The workout id was not known here and the snapshot was stored.
    case inserted
    /// A newer revision replaced what was stored.
    case accepted
    /// An older revision arrived late and was discarded.
    case ignored
    /// The same revision arrived again; stored state was left untouched.
    case idempotent

    public var didStore: Bool {
        self == .inserted || self == .accepted
    }

    /// Only a revision that was actually stored gets acknowledged. Acking an
    /// ignored or duplicate delivery would tell the sender its stale edit won.
    public func acknowledgement(
        for workoutID: UUID,
        revision: Int,
        origin: SyncEnvelope.Origin,
        now: Date = Date()
    ) -> SyncEnvelope? {
        guard didStore else { return nil }
        return SyncEnvelope(
            event: .workoutSyncAck,
            workoutID: workoutID,
            revision: revision,
            updatedAt: now,
            origin: origin
        )
    }
}

/// Revision-ordered storage for workouts held on this device.
///
/// Delivery over WatchConnectivity is neither ordered nor exactly-once, so the
/// only safe merge rule is "highest revision wins" — which also makes replay
/// harmless.
public struct WorkoutStore: Equatable, Sendable {

    private var workouts: [UUID: WorkoutDraft] = [:]

    public init(_ workouts: [WorkoutDraft] = []) {
        for workout in workouts { self.workouts[workout.id] = workout }
    }

    public var count: Int { workouts.count }

    public var all: [WorkoutDraft] {
        workouts.values.sorted { $0.updatedAt > $1.updatedAt }
    }

    public func workout(_ id: UUID) -> WorkoutDraft? { workouts[id] }

    @discardableResult
    public mutating func apply(_ snapshot: WorkoutDraft) -> ReconcileOutcome {
        guard let existing = workouts[snapshot.id] else {
            workouts[snapshot.id] = snapshot
            return .inserted
        }
        if snapshot.revision > existing.revision {
            workouts[snapshot.id] = snapshot
            return .accepted
        }
        return snapshot.revision == existing.revision ? .idempotent : .ignored
    }

    /// Local edits bypass reconciliation — this device is the author.
    public mutating func store(_ workout: WorkoutDraft) {
        workouts[workout.id] = workout
    }

    public mutating func remove(_ id: UUID) {
        workouts.removeValue(forKey: id)
    }
}
