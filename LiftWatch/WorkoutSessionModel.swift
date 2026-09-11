import Foundation
import LiftKit
import SwiftUI

/// Owns the workout the watch is training against right now.
///
/// The watch is authoritative for its own edits: it writes locally first and
/// only then tries the phone. Nothing here blocks on connectivity, because the
/// phone is regularly out of range mid-set.
@MainActor
final class WorkoutSessionModel: ObservableObject {

    @Published private(set) var draft: WorkoutDraft?
    @Published private(set) var store = WorkoutStore()
    @Published private(set) var outbox = SyncOutbox()
    @Published var restTimer = RestTimer()
    @Published var unit: WeightUnit = .pounds
    @Published var servingUnit: ServingUnit = .grams
    @Published private(set) var isPhoneReachable = false
    @Published private(set) var recentFoodsSnapshot: RecentFoodsSnapshot?

    private let transport: PhoneSyncTransport
    private let foodSnapshotStore: RecentFoodsSnapshotStore

    init(transport: PhoneSyncTransport = PhoneSyncTransport(),
         foodSnapshotStore: RecentFoodsSnapshotStore = RecentFoodsSnapshotStore()) {
        self.transport = transport
        self.foodSnapshotStore = foodSnapshotStore
        recentFoodsSnapshot = foodSnapshotStore.cached
        transport.onEnvelope = { [weak self] envelope in
            Task { @MainActor in self?.receive(envelope) }
        }
        transport.onReachabilityChange = { [weak self] reachable in
            Task { @MainActor in
                self?.isPhoneReachable = reachable
                if reachable { self?.flushOutbox() }
            }
        }
        transport.onApplicationContext = { [weak self] context in
            Task { @MainActor in self?.receiveApplicationContext(context) }
        }
        transport.activate()
        if let latest = transport.latestApplicationContext() {
            receiveApplicationContext(latest)
        }
    }

    // MARK: - Training

    func startWorkout(named name: String, focus: TrainingFocus = .bodybuilding) {
        let workout = WorkoutDraft(name: name, focus: focus)
        draft = workout
        store.store(workout)
    }

    func addExercise(refID: String, name: String, equipment: String? = nil) {
        edit { $0.addExercise(refID: refID, name: name, equipment: equipment) }
    }

    func logSet(to exerciseID: UUID, weight: Double, reps: Int, rpe: Double? = nil) {
        let weightKg = unit.toKilograms(weight)
        edit { draft in
            guard let setID = draft.appendSet(to: exerciseID, weightKg: weightKg,
                                              reps: reps, rpe: rpe) else { return }
            draft.completeSet(setID)
        }
        restTimer.start()
    }

    func finishWorkout() {
        edit { $0.finish() }
        restTimer.stop()
        if let draft { enqueue(.sessionFinished, for: draft) }
    }

    /// Applies a local edit, persists it, and tells the phone — in that order,
    /// so a failed send never costs the user their set.
    private func edit(_ change: (inout WorkoutDraft) -> Void) {
        guard var current = draft else { return }
        let revisionBefore = current.revision
        change(&current)
        guard current.revision != revisionBefore else { return }
        draft = current
        store.store(current)
        enqueue(.workoutEdited, for: current)
    }

    // MARK: - Synchronization

    private func enqueue(_ event: SyncEnvelope.Event, for workout: WorkoutDraft) {
        enqueue(event, workoutID: workout.id, revision: workout.revision, updatedAt: workout.updatedAt)
    }

    /// Entry point for sync notifications that don't originate from a
    /// `WorkoutDraft` — currently just `OutdoorActivityLibrary.finish(_:)`.
    ///
    /// `OutdoorActivityLibrary` has no `SyncOutbox`/`PhoneSyncTransport` of
    /// its own and deliberately doesn't get one: `WCSession` supports exactly
    /// one delegate per process, and `PhoneSyncTransport` claims that slot in
    /// its initializer, so a second instance built from `WCSession.default`
    /// would silently steal reachability/message callbacks away from this
    /// model's transport rather than adding a second listener. Routing
    /// through this model's existing outbox/transport (it holds the app's
    /// only `PhoneSyncTransport`, injected once from `LiftWatchApp`) avoids
    /// standing up that conflict for one notification event.
    func enqueueOutdoorActivityFinished(id: UUID, revision: Int, updatedAt: Date) {
        enqueue(.outdoorActivityFinished, workoutID: id, revision: revision, updatedAt: updatedAt)
    }

    /// Fire-and-forget, exactly like `enqueueOutdoorActivityFinished`: the
    /// phone computes and persists the actual `FoodEntry`, so there is
    /// nothing here to reconcile a revision against. `workoutID` is a fresh,
    /// one-shot UUID (per `FoodLogPayload`'s doc comment) — since it is
    /// unique per call, `SyncOutbox`'s per-`workoutID` collapsing never
    /// merges two distinct food logs together.
    func enqueueFoodLogged(foodRefID: String, amountGrams: Double, meal: FoodLogMeal, loggedAt: Date = .now) {
        let payload = FoodLogPayload(foodRefID: foodRefID, amountGrams: amountGrams,
                                      meal: meal.rawValue, loggedAt: loggedAt)
        enqueue(.foodLogged, workoutID: UUID(), revision: 1, updatedAt: loggedAt, foodLog: payload)
    }

    private func enqueue(_ event: SyncEnvelope.Event, workoutID: UUID, revision: Int,
                          updatedAt: Date, foodLog: FoodLogPayload? = nil) {
        let envelope = SyncEnvelope(
            event: event,
            workoutID: workoutID,
            revision: revision,
            updatedAt: updatedAt,
            origin: .watchOS,
            foodLog: foodLog
        )
        outbox.enqueue(envelope)
        flushOutbox()
    }

    /// Always attempts delivery via `transport.send`, regardless of current
    /// reachability — `PhoneSyncTransport.send` uses `transferUserInfo`,
    /// which the OS queues and delivers once the phone comes back in range,
    /// even across this app being suspended or terminated in the meantime.
    /// Gating this on `transport.isReachable` (as this used to) would only
    /// have delayed delivery to the next explicit flush trigger for no
    /// benefit, since the in-memory `SyncOutbox` itself is what can't survive
    /// termination — the OS-level queue `transferUserInfo` hands off to can.
    private func flushOutbox() {
        guard !outbox.isEmpty else { return }
        // Entries stay queued until the phone acknowledges the revision; a send
        // that silently fails must not look like a delivery. `.foodLogged` is
        // the one exception: it's a one-shot request with nothing to
        // reconcile (see `enqueueFoodLogged`'s doc comment), and the phone
        // never sends a `WORKOUT_SYNC_ACK` for it — so it must be removed
        // right after sending, or it resends (and re-inserts a duplicate
        // `FoodEntry`) on every later flush.
        for envelope in outbox.pending {
            transport.send(envelope)
            if envelope.event == .foodLogged {
                outbox.remove(workoutID: envelope.workoutID)
            }
        }
    }

    private func receiveApplicationContext(_ context: [String: Any]) {
        guard let snapshot = try? RecentFoodsSnapshot(applicationContext: context) else { return }
        recentFoodsSnapshot = snapshot
        foodSnapshotStore.save(snapshot)
    }

    private func receive(_ envelope: SyncEnvelope) {
        switch envelope.event {
        case .workoutSyncAck:
            outbox.acknowledge(envelope)
        case .foodLogged:
            // The phone never echoes this back — it refreshes the watch via a
            // separate, non-`SyncEnvelope` channel (`RecentFoodsSnapshot` via
            // `updateApplicationContext`, see `RecentFoodsSnapshotStore`).
            // This case exists only so the switch stays exhaustive.
            break
        case .workoutEdited, .sessionFinished, .outdoorActivityFinished:
            // The envelope is a notification, not the workout. A full snapshot
            // fetch belongs here once the phone exposes one; until then the
            // revision is recorded so the outbox does not resend needlessly.
            // (In practice the watch only ever sends `.outdoorActivityFinished`,
            // never receives it back, but the switch must stay exhaustive.)
            outbox.acknowledge(
                SyncEnvelope(event: .workoutSyncAck, workoutID: envelope.workoutID,
                             revision: envelope.revision, updatedAt: envelope.updatedAt,
                             origin: .watchOS)
            )
        }
    }
}
