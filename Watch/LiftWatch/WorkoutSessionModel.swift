import Foundation
import LiftKit
import SwiftUI
import LiftSync

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
    /// Retained regardless of whether a phone exists. See
    /// `StandaloneFoodLog`'s doc comment for why `SyncOutbox` cannot serve
    /// this purpose.
    let foodLog = StandaloneFoodLog()
    @Published var restTimer = RestTimer()
    @Published var unit: WeightUnit = .pounds
    @Published var servingUnit: ServingUnit = .grams
    @Published private(set) var isPhoneReachable = false
    @Published private(set) var recentFoodsSnapshot: RecentFoodsSnapshot?

    /// Today's plan, as the phone last pushed it. `nil` is not a failure —
    /// it is the free-entry flow this app has always had, unchanged.
    @Published private(set) var plan: WorkoutPlan?
    /// Where the lifter is inside that plan. Non-nil only while a planned
    /// workout is actually being trained.
    @Published private(set) var guided: GuidedSession?

    /// The plan's identity and revision, straight off the envelope — the
    /// same reconciliation rule `WorkoutStore` applies to a workout: a newer
    /// revision replaces, an older one is ignored.
    private var planID: UUID?
    private var planRevision = 0
    /// Keeps the triggers that ask for a plan together — the app becoming
    /// active, the phone becoming reachable — from asking twice.
    private var planRequests = PlanRequestGate()

    /// What rest to start when the set just logged prescribed none. Matches
    /// `RestTimer`'s own default, so an unplanned session rests exactly as it
    /// did before any of this existed.
    static let defaultRestSeconds = 90

    private let transport: PhoneSyncTransport
    private let foodSnapshotStore: RecentFoodsSnapshotStore
    /// Heart rate and wrist-down runtime for a lifting session. Optional so
    /// a test (or a preview) can build a model with no HealthKit at all.
    private let heartRate: LiftingSessionRecorder?

    init(transport: PhoneSyncTransport = PhoneSyncTransport(),
         foodSnapshotStore: RecentFoodsSnapshotStore = RecentFoodsSnapshotStore(),
         heartRate: LiftingSessionRecorder? = nil) {
        self.transport = transport
        self.foodSnapshotStore = foodSnapshotStore
        self.heartRate = heartRate
        recentFoodsSnapshot = foodSnapshotStore.cached
        transport.onEnvelope = { [weak self] envelope in
            Task { @MainActor in self?.receive(envelope) }
        }
        transport.onReachabilityChange = { [weak self] reachable in
            Task { @MainActor in
                self?.isPhoneReachable = reachable
                if reachable {
                    self?.flushOutbox()
                    // The phone pushes on its own activation too, but this
                    // covers the watch waking first: asking costs one queued
                    // envelope and answers the question the Now screen needs
                    // answered before the lifter starts.
                    self?.requestPlan()
                }
            }
        }
        transport.onApplicationContext = { [weak self] context in
            Task { @MainActor in self?.receiveApplicationContext(context) }
        }
        transport.activate()
        if let latest = transport.latestApplicationContext() {
            receiveApplicationContext(latest)
        }
        #if DEBUG
        ingestEnvelopeFromLaunchEnvironment()
        #endif
    }

    #if DEBUG
    /// Accepts one `SyncEnvelope`, as JSON, from the launch environment:
    ///
    ///     SIMCTL_CHILD_LIFT_SYNC_ENVELOPE="$(cat plan.json)" \
    ///       xcrun simctl launch booted com.dugcanlift.watch
    ///
    /// DEBUG only, and it exists because a plan cannot otherwise be put in
    /// front of this app on a simulator: LIFT iOS is very likely not this
    /// app's `WCSession` peer at all (`WKWatchOnly`, a different bundle id,
    /// no embedded watch target — see the transport note in
    /// `docs/ARCHITECTURE.md`), and a paired simulator pair reports
    /// `isWatchAppInstalled == false` from the phone, so every
    /// `transferUserInfo` queues into nothing.
    ///
    /// It deliberately goes through `receive(_:)`, the same method the
    /// transport calls, rather than assigning `plan` directly: the decode,
    /// the revision rule and the guided start are then the real ones, and
    /// only the delivery is by hand.
    private func ingestEnvelopeFromLaunchEnvironment() {
        guard let json = ProcessInfo.processInfo.environment["LIFT_SYNC_ENVELOPE"],
              let data = json.data(using: .utf8),
              let envelope = try? SyncEnvelope.decoder.decode(SyncEnvelope.self, from: data)
        else { return }
        receive(envelope)
    }
    #endif

    // MARK: - Training

    func startWorkout(named name: String, focus: TrainingFocus = .bodybuilding) {
        let workout = WorkoutDraft(name: name, focus: focus)
        draft = workout
        store.store(workout)
        heartRate?.start()
    }

    /// Starts today's plan: one draft exercise per planned exercise, in the
    /// plan's own order, and a `GuidedSession` tracking position through it.
    ///
    /// What gets logged is an ordinary `WorkoutDraft` — the plan decides what
    /// to put in front of the lifter, never what a set *is* — so revisions,
    /// the outbox and `SESSION_FINISHED` behave exactly as they do for a
    /// workout typed in from nothing.
    func startPlannedWorkout() {
        guard let plan, !plan.exercises.isEmpty else { return }
        let exercises = plan.exercises.enumerated().map { index, exercise in
            DraftExercise(
                // The plan carries no exercise ids (PLAN-FORMAT gives
                // workouts none), so position is the reference — and it is
                // stable, because the draft is built from the plan once and
                // the plan is never swapped underneath a running session.
                exerciseRefID: "plan:\(index)",
                name: exercise.name,
                orderIndex: index,
                equipment: exercise.equipment,
                sets: []
            )
        }
        let workout = WorkoutDraft(name: plan.name, exercises: exercises)
        draft = workout
        store.store(workout)
        guided = GuidedSession(plan: plan)
        heartRate?.start()
    }

    /// The draft exercise the guided session is currently on, or `nil` when
    /// nothing is being guided.
    var guidedExerciseID: UUID? {
        guard let guided, let draft, let index = guided.currentExerciseIndex,
              draft.exercises.indices.contains(index) else { return nil }
        return draft.exercises[index].id
    }

    /// The prescription for the set about to be logged against `exerciseID`,
    /// or `nil` when that exercise is not the guided one.
    func prescription(for exerciseID: UUID) -> PrescribedSet? {
        guard guidedExerciseID == exerciseID else { return nil }
        return guided?.currentPrescription
    }

    func lastPerformed(for exerciseID: UUID) -> LastPerformed? {
        guard guidedExerciseID == exerciseID else { return nil }
        return guided?.currentExercise?.lastPerformed
    }

    /// Moves the guided session to whichever exercise the lifter opened, so
    /// training out of order is a tap rather than a wrong prescription.
    func focusGuidedSession(on exerciseID: UUID) {
        guard guided != nil, let draft,
              let index = draft.exercises.firstIndex(where: { $0.id == exerciseID })
        else { return }
        guided?.select(exerciseIndex: index)
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

        // Rest is the one the set just performed prescribed — not the next
        // set's, and not the next exercise's. `recordSet()` also advances the
        // position, and the next exercise when this one's sets are done.
        var prescribedRest: Int?
        if guidedExerciseID == exerciseID {
            prescribedRest = guided?.recordSet()?.restSeconds
        }
        restTimer.interval = TimeInterval(prescribedRest ?? Self.defaultRestSeconds)
        restTimer.start()
    }

    func finishWorkout() {
        edit { $0.finish() }
        restTimer.stop()
        // Ends the HealthKit session and hands back the two numbers the
        // phone gets. `nil` when nothing was ever measured — a simulator, a
        // refused permission — and the envelope then omits the key rather
        // than reporting a heart rate of zero.
        let sessionHeartRate = heartRate?.finish()
        if let draft {
            enqueue(.sessionFinished, for: draft, heartRate: sessionHeartRate)
        }
        guided = nil
    }

    // MARK: - Plans

    /// Asks the phone for today's plan. Fire and forget: the answer arrives
    /// as a `PLAN_PUSHED` whenever the phone next has a chance to send one,
    /// which may be after the app is suspended, so nothing here waits.
    ///
    /// Automatic triggers go through `PlanRequestGate`, so the app becoming
    /// active and the phone becoming reachable in the same moment ask once.
    /// `force` is for the lifter's own tap, which always asks.
    func requestPlan(force: Bool = false) {
        guard planRequests.shouldRequest(reachable: transport.isReachable, now: .now, force: force)
        else { return }
        transport.sendNow(SyncEnvelope(
            event: .planRequest,
            workoutID: UUID(),
            revision: 1,
            updatedAt: .now,
            origin: .watchOS
        ))
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

    private func enqueue(_ event: SyncEnvelope.Event, for workout: WorkoutDraft,
                          heartRate: SessionHeartRate? = nil) {
        enqueue(event, workoutID: workout.id, revision: workout.revision,
                updatedAt: workout.updatedAt, heartRate: heartRate)
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

    /// Sends a food to the phone: the phone computes and persists the actual
    /// `FoodEntry`, so there is nothing here to reconcile a revision against.
    /// `workoutID` is a fresh, one-shot UUID (per `FoodLogPayload`'s doc
    /// comment) — since it is unique per call, `SyncOutbox`'s per-`workoutID`
    /// collapsing never merges two distinct food logs together.
    ///
    /// Returns that id. The phone acknowledges a stored food with a
    /// `WORKOUT_SYNC_ACK` carrying it, which is what takes the food back out
    /// of the standalone log (`recordLocally(syncID:)`, `receive(_:)`).
    @discardableResult
    func enqueueFoodLogged(foodRefID: String, amountGrams: Double, meal: FoodLogMeal,
                           loggedAt: Date = .now) -> UUID {
        let syncID = UUID()
        let payload = FoodLogPayload(foodRefID: foodRefID, amountGrams: amountGrams,
                                      meal: meal.rawValue, loggedAt: loggedAt)
        enqueue(.foodLogged, workoutID: syncID, revision: 1, updatedAt: loggedAt, foodLog: payload)
        return syncID
    }

    /// Records a food in the retained local log. Called alongside
    /// `enqueueFoodLogged`, with the id it returned, when a `foodRefID`
    /// exists — the entry then leaves the log once the phone acknowledges
    /// it — and on its own, with no id, when the food came from the bundled
    /// library and never goes to the phone at all.
    func recordLocally(food: WatchFood, grams: Double, meal: FoodLogMeal,
                       loggedAt: Date = .now, syncID: UUID? = nil) {
        foodLog.append(LoggedFood(food: food, grams: grams, meal: meal,
                                  loggedAt: loggedAt, syncID: syncID))
    }

    private func enqueue(_ event: SyncEnvelope.Event, workoutID: UUID, revision: Int,
                          updatedAt: Date, foodLog: FoodLogPayload? = nil,
                          heartRate: SessionHeartRate? = nil) {
        let envelope = SyncEnvelope(
            event: event,
            workoutID: workoutID,
            revision: revision,
            updatedAt: updatedAt,
            origin: .watchOS,
            foodLog: foodLog,
            heartRate: heartRate
        )
        outbox.enqueue(envelope)
        flushOutbox()
    }

    /// Always attempts delivery, regardless of current reachability —
    /// `PhoneSyncTransport.send` uses `transferUserInfo`, which the OS queues
    /// and delivers once the phone comes back in range, even across this app
    /// being suspended or terminated in the meantime. Gating this on
    /// `transport.isReachable` (as this used to) would only have delayed
    /// delivery to the next explicit flush trigger for no benefit, since the
    /// in-memory `SyncOutbox` itself is what can't survive termination — the
    /// OS-level queue `transferUserInfo` hands off to can.
    private func flushOutbox() {
        guard !outbox.isEmpty else { return }
        // Entries stay queued until the phone acknowledges the revision; a send
        // that silently fails must not look like a delivery. `.foodLogged` is
        // the one exception: it's a one-shot request with nothing to
        // reconcile (see `enqueueFoodLogged`'s doc comment), so it is removed
        // right after sending, or it would resend on every later flush. Its
        // acknowledgement matters to the standalone log, not to this queue:
        // the OS queue behind `transferUserInfo` already holds it durably.
        //
        // A food goes by `sendNow`: `sendMessage` when the phone is reachable,
        // so it is in LIFT for iPhone — and acknowledged, and out of the
        // standalone log — within a second or two rather than whenever the
        // OS gets round to the queue, falling back to `transferUserInfo`
        // otherwise. The phone ignores a food id it has already stored, so a
        // message that arrived but reported an error, and was then queued as
        // well, is not logged twice.
        for envelope in outbox.pending {
            if envelope.event == .foodLogged {
                transport.sendNow(envelope)
                outbox.remove(workoutID: envelope.workoutID)
            } else {
                transport.send(envelope)
            }
        }
    }

    private func receiveApplicationContext(_ context: [String: Any]) {
        guard let snapshot = try? RecentFoodsSnapshot(messageBody: context) else { return }
        recentFoodsSnapshot = snapshot
        foodSnapshotStore.save(snapshot)
    }

    /// Accepts a pushed plan under the contract's own conflict rule: a newer
    /// revision for the same plan replaces what is held, the same or an older
    /// one is ignored. A different plan id always replaces — the phone
    /// decides what today is, and the watch does not argue about it.
    ///
    /// A plan that lands mid-session is stored but does not disturb the
    /// session in progress: `GuidedSession` is built once, at start, so a
    /// coach editing a routine while someone is under a bar cannot move
    /// their position or change the set they are about to log. It takes
    /// effect the next time a planned workout is started.
    private func receivePlan(_ envelope: SyncEnvelope) {
        guard let pushed = envelope.plan else { return }
        if envelope.workoutID == planID, envelope.revision <= planRevision { return }
        planID = envelope.workoutID
        planRevision = envelope.revision
        plan = pushed
    }

    private func receive(_ envelope: SyncEnvelope) {
        switch envelope.event {
        case .workoutSyncAck:
            outbox.acknowledge(envelope)
            // The phone acknowledges a stored `FOOD_LOGGED` the same way,
            // under the food's one-shot id. It is in LIFT for iPhone now, so
            // it leaves the standalone log, or an export would count it a
            // second time. A workout's id matches nothing there.
            foodLog.acknowledge(syncID: envelope.workoutID)
        case .foodLogged:
            // The phone never echoes this back — it refreshes the watch via a
            // separate, non-`SyncEnvelope` channel (`RecentFoodsSnapshot` via
            // `updateApplicationContext`, see `RecentFoodsSnapshotStore`).
            // This case exists only so the switch stays exhaustive.
            break
        case .planPushed:
            receivePlan(envelope)
        case .planRequest:
            // Watch -> phone only. Nothing here asks this watch for a plan.
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
