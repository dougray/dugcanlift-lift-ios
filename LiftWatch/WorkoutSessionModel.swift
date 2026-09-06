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
    @Published private(set) var isPhoneReachable = false

    private let transport: PhoneSyncTransport

    init(transport: PhoneSyncTransport = PhoneSyncTransport()) {
        self.transport = transport
        transport.onEnvelope = { [weak self] envelope in
            Task { @MainActor in self?.receive(envelope) }
        }
        transport.onReachabilityChange = { [weak self] reachable in
            Task { @MainActor in
                self?.isPhoneReachable = reachable
                if reachable { self?.flushOutbox() }
            }
        }
        transport.activate()
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
        let envelope = SyncEnvelope(
            event: event,
            workoutID: workout.id,
            revision: workout.revision,
            updatedAt: workout.updatedAt,
            origin: .watchOS
        )
        outbox.enqueue(envelope)
        flushOutbox()
    }

    private func flushOutbox() {
        guard transport.isReachable, !outbox.isEmpty else { return }
        // Entries stay queued until the phone acknowledges the revision; a send
        // that silently fails must not look like a delivery.
        for envelope in outbox.pending {
            transport.send(envelope)
        }
    }

    private func receive(_ envelope: SyncEnvelope) {
        switch envelope.event {
        case .workoutSyncAck:
            outbox.acknowledge(envelope)
        case .workoutEdited, .sessionFinished:
            // The envelope is a notification, not the workout. A full snapshot
            // fetch belongs here once the phone exposes one; until then the
            // revision is recorded so the outbox does not resend needlessly.
            outbox.acknowledge(
                SyncEnvelope(event: .workoutSyncAck, workoutID: envelope.workoutID,
                             revision: envelope.revision, updatedAt: envelope.updatedAt,
                             origin: .watchOS)
            )
        }
    }
}
