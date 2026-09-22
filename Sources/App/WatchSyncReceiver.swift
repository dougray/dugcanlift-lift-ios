import Foundation
import WatchConnectivity
import SwiftData
import WidgetKit
import LiftCore
import LiftSync

/// The phone's only `WCSessionDelegate` — mirrors the watch's own
/// `PhoneSyncTransport` on the other end of the same wire format. Decodes
/// every incoming `SyncEnvelope` and dispatches on `event`; only
/// `.foodLogged` does anything today, but the dispatch structure exists so
/// a future watch-originated feature adds a case, not new plumbing.
final class WatchSyncReceiver: NSObject, WCSessionDelegate {

    /// The one instance the running app actually uses, built against the
    /// same `mainContext` every view already writes through via
    /// `.modelContainer(LiftStore.shared)` in `LiftApp`. This is the only
    /// place in the codebase that needs "notify another subsystem after a
    /// write" — there's no existing NotificationCenter or delegate-callback
    /// convention for that here, but there IS an existing convention for
    /// "the one shared instance of a thing": `LiftStore.shared`. A static
    /// `shared` matches that shape and lets every phone-originated logging
    /// call site (`FoodSearchView`, `FoodView.logAgain`, `CookView`'s
    /// planned-meal logging) reach it without LiftApp having to hand out a
    /// reference through the view hierarchy.
    ///
    /// Set once via `activate(context:)`, from `LiftApp`, rather than a
    /// plain `static let` initialized with `LiftStore.shared.mainContext`
    /// right here: `ModelContainer.mainContext` is `@MainActor`-isolated,
    /// and a static property initializer's own context is not implicitly
    /// isolated to the main actor, so that read has to happen somewhere
    /// that already is — `LiftApp.init()`, which SwiftUI's `App` protocol
    /// itself declares `@MainActor`.
    static private(set) var shared: WatchSyncReceiver?

    private let context: ModelContext
    private let defaults: UserDefaults
    /// Where an outgoing envelope goes. `nil` is WatchConnectivity
    /// (`sendOverSession`); a test passes a closure to see what was sent,
    /// since no `WCSession` activates in a unit test process.
    private let sender: ((SyncEnvelope) -> Void)?

    init(context: ModelContext, defaults: UserDefaults = .standard,
         sender: ((SyncEnvelope) -> Void)? = nil) {
        self.context = context
        self.defaults = defaults
        self.sender = sender
        super.init()
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }

    /// Installs `.shared`. Called once, from `LiftApp.init()`, at launch.
    @MainActor
    static func activate(context: ModelContext) {
        shared = WatchSyncReceiver(context: context)
    }

    // WatchConnectivity delivers this on a background serial queue, not the
    // main actor. `pushRecentFoodsSnapshot()` is `@MainActor` (it reads
    // `context`, a `@MainActor`-isolated `ModelContext`), so hop explicitly
    // rather than calling it synchronously from here.
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        guard activationState == .activated else { return }
        Task { @MainActor in
            pushRecentFoodsSnapshot()
            // The watch asks for a plan when it becomes active, but it can
            // only ask once this session is up on both ends; pushing here
            // covers the case where the watch app woke first and its
            // request arrived before there was anyone to hear it.
            pushTodaysPlan()
        }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) { WCSession.default.activate() }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        deliver(userInfo)
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        deliver(message)
    }

    private func deliver(_ body: [String: Any]) {
        // `SyncEnvelope(messageBody:)` (Task 1) decodes with the type's own
        // `.iso8601`-configured decoder — a plain `JSONDecoder()` here would
        // fail on every `updatedAt`/`loggedAt` string the watch actually
        // sends.
        guard let envelope = try? SyncEnvelope(messageBody: body) else { return }
        Task { @MainActor in
            await handle(envelope)
        }
    }

    /// `internal`, not `private`, so tests can drive dispatch directly
    /// without going through `WCSession` message delivery at all.
    @MainActor
    @discardableResult
    func handle(_ envelope: SyncEnvelope) async -> Bool {
        switch envelope.event {
        case .foodLogged:
            return await handleFoodLogged(envelope)
        case .planRequest:
            // The watch asks on becoming active, which is exactly when it
            // needs an answer, so this pushes immediately rather than
            // waiting for some later trigger.
            return pushTodaysPlan()
        case .sessionFinished:
            return handleSessionFinished(envelope)
        case .planPushed:
            // Phone -> watch only. Receiving one means the watch echoed our
            // own push back, which nothing does; ignore rather than act on
            // a plan this device is the author of.
            return false
        case .workoutEdited, .workoutSyncAck, .outdoorActivityFinished:
            return false // no phone-side handler yet for these
        }
    }

    // MARK: - Plans

    /// Builds today's plan and sends it to the watch, returning whether
    /// there was one to send. No plan today is not a failure — it is the
    /// watch's free-entry flow, unchanged, and sending an empty plan would
    /// replace that with an empty guided session.
    ///
    /// Called on activation, when the watch asks (`PLAN_REQUEST`), when a
    /// coach's plan link is accepted, and when the lifter sends a routine by
    /// hand from Routines.
    @MainActor
    @discardableResult
    func pushTodaysPlan(on date: Date = .now, defaults: UserDefaults = .standard) -> Bool {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else { return false }
        guard let pushable = WatchPlanBuilder.todaysPlan(
            on: date,
            in: context,
            restSeconds: WatchPlanSettings.resolvedRestSeconds(in: defaults),
            defaults: defaults
        ) else { return false }

        var revisions = WatchPlanRevisions.load(from: defaults)
        let revision = revisions.revision(
            for: pushable.id,
            contentHash: WatchPlanRevisions.contentHash(of: pushable.plan)
        )
        revisions.save(to: defaults)

        send(SyncEnvelope(
            event: .planPushed,
            workoutID: pushable.id,
            revision: revision,
            updatedAt: .now,
            origin: .ios,
            plan: pushable.plan
        ))
        return true
    }

    /// The watch app is this app's companion (`Watch/`, embedded at
    /// `Lift.app/Watch/LIFT.app`), which is what makes the two `WCSession`
    /// peers. It was a separate `WKWatchOnly` app until 2026-09, and on a
    /// paired simulator pair this side then reported
    /// `isWatchAppInstalled == false` and nothing it sent arrived; as a
    /// companion both sides report the other installed, and a plan, the
    /// recent-foods context and a food all make the round trip.
    ///
    /// One exception on the simulator only: `transferUserInfo` is never
    /// delivered between a paired iPhone and Apple Watch *simulator*, in
    /// either direction (Apple DTS: the watchOS Simulator does not support
    /// it; the payload reaches the peer's `wcd` and is dropped there). So on
    /// a simulator only the `sendMessage` fast path below is seen to work,
    /// and the queued path can only be checked on real devices.
    ///
    /// `transferUserInfo` is the delivery that matters: the OS queues it and
    /// hands it over when the watch is next in range, which is the whole
    /// point — a plan pushed while the watch is on a charger in another room
    /// must still be there when it is picked up. `sendMessage` is only a
    /// fast path for a watch that is awake right now, and its failure falls
    /// back to the queue rather than dropping the plan.
    private func send(_ envelope: SyncEnvelope) {
        if let sender {
            sender(envelope)
        } else {
            Self.sendOverSession(envelope)
        }
    }

    private static func sendOverSession(_ envelope: SyncEnvelope) {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated,
              let body = try? envelope.messageBody() else { return }
        let session = WCSession.default
        guard session.isReachable else {
            session.transferUserInfo(body)
            return
        }
        session.sendMessage(body, replyHandler: nil) { _ in
            session.transferUserInfo(body)
        }
    }

    // MARK: - Session heart rate

    /// Heart rate for the last lifting session the watch finished, average
    /// and max.
    ///
    /// Kept here rather than written onto the day: `WorkoutDay` has no heart
    /// rate columns, and adding them is a schema change for a store two
    /// shipped apps share (see CLAUDE.md, "A struct a model stores is part
    /// of the schema"). The samples themselves are in HealthKit already,
    /// written by the watch as part of its own workout, so nothing is lost
    /// by not duplicating them into SwiftData — what is missing is only a
    /// phone screen that shows these two numbers, which this task does not
    /// add.
    @MainActor
    @discardableResult
    private func handleSessionFinished(_ envelope: SyncEnvelope,
                                       defaults: UserDefaults = .standard) -> Bool {
        guard let heartRate = envelope.heartRate else { return false }
        WatchSessionHeartRateStore.record(heartRate, for: envelope.workoutID, in: defaults)
        return true
    }

    /// Stores a food the watch logged, once, and tells the watch it has.
    ///
    /// **Once**: the envelope's `workoutId` is the food's one-shot id, and an
    /// id already stored is not stored again. The watch sends a food by
    /// `sendMessage` when this phone is reachable and falls back to
    /// `transferUserInfo` if that reports an error, and an error does not
    /// prove the message was not delivered.
    ///
    /// **Tells the watch**: a `WORKOUT_SYNC_ACK` under the same id, revision
    /// and all, the way `FOOD_LOGGED` already borrows the workout fields.
    /// That takes the food out of the watch's standalone log, which it keeps
    /// until then in case this phone never receives it; left there, a QR
    /// export of that log would put the meal into the web app a second time.
    /// A repeat is acknowledged again, since the first acknowledgement may
    /// be the thing that was lost. An older watch build files the
    /// acknowledgement under its outbox, finds no such workout, and ignores
    /// it.
    @MainActor
    @discardableResult
    private func handleFoodLogged(_ envelope: SyncEnvelope) async -> Bool {
        if WatchFoodLogReceipts.contains(envelope.workoutID, in: defaults) {
            acknowledge(envelope)
            return true
        }
        guard let payload = envelope.foodLog,
              let resolved = await FoodRefResolver.nutrition(for: payload.foodRefID, grams: payload.amountGrams, context: context),
              let mealType = MealType(rawValue: payload.meal.lowercased())
        else { return false }

        let entry = FoodEntry(
            foodRefID: payload.foodRefID,
            name: resolved.name,
            quantity: payload.amountGrams,
            servingUnit: "g",
            amountGrams: payload.amountGrams,
            nutrition: resolved.nutrition,
            mealType: mealType,
            loggedAt: payload.loggedAt
        )
        context.insert(entry)
        do {
            try context.save()
        } catch {
            // Not stored, so not acknowledged: the watch keeps the food
            // exportable, which is the point of asking before it lets go.
            context.delete(entry)
            return false
        }
        WatchFoodLogReceipts.record(envelope.workoutID, in: defaults)
        acknowledge(envelope)
        WidgetCenter.shared.reloadAllTimelines()
        pushRecentFoodsSnapshot()
        return true
    }

    @MainActor
    private func acknowledge(_ envelope: SyncEnvelope) {
        send(SyncEnvelope(
            event: .workoutSyncAck,
            workoutID: envelope.workoutID,
            revision: envelope.revision,
            updatedAt: .now,
            origin: .ios
        ))
    }

    /// Pushed on activation and after every watch-originated food log, so
    /// the watch's local cache stays reasonably fresh. Also called from
    /// every phone-originated logging call site (`FoodSearchView.log`,
    /// `FoodView.logAgain`, `CookView`'s planned-meal logging) — see those
    /// files for the call — so a phone-logged food reaches the watch's
    /// cache immediately rather than waiting for some unrelated sync event.
    @MainActor
    func pushRecentFoodsSnapshot() {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else { return }
        let recent = RecentFoodsQuery.recent(context: context, limit: 20)
        let snapshot = Self.makeSnapshot(from: recent)
        guard let dict = try? snapshot.messageBody() else { return }
        try? WCSession.default.updateApplicationContext(dict)
    }

    /// The pure phone -> watch mapping half of `pushRecentFoodsSnapshot()`,
    /// pulled out so it's testable without a real, activated `WCSession` —
    /// the `activationState == .activated` guard above never passes in a
    /// unit test process, so this was previously untested even though it's
    /// the exact contract the watch-side plan builds against. `internal`,
    /// not `private`, so `WatchSyncReceiverTests` can call it directly.
    static func makeSnapshot(from entries: [FoodEntry], generatedAt: Date = .now) -> RecentFoodsSnapshot {
        // A Road Food item has a stable id but nothing the watch can resolve
        // to grams and nutrition (`FoodRefResolver` knows reference foods and
        // recipes), so offering it there would be a tap that logs nothing.
        let items = entries
            .filter { !$0.foodRefID.isEmpty && !$0.foodRefID.hasPrefix(RoadFoodRanking.foodRefPrefix) }
            .map {
                RecentFoodsSnapshot.Item(foodRefID: $0.foodRefID, displayName: $0.displayName,
                                         lastAmountGrams: $0.amountGrams,
                                         nutritionPer100g: nutritionPer100g(of: $0))
            }
        return RecentFoodsSnapshot(items: items, generatedAt: generatedAt)
    }

    /// The entry's macros per 100 g, which the snapshot schema has carried
    /// (`nutritionPer100g`) since the watch learned to export its own food
    /// log, and which this app never filled in. Without them the watch cannot
    /// keep a food it logs from this list in its standalone log, so a food
    /// whose `FOOD_LOGGED` never reached this phone was in neither place;
    /// the watch counted it as "can't be exported yet. Update LIFT on your
    /// iPhone." With them, the watch keeps it until this app acknowledges it
    /// (`handleFoodLogged`).
    ///
    /// `nil` rather than a guess whenever the entry cannot say: no gram
    /// amount to divide by, or no fibre figure, because `WatchFood.fibre` is
    /// not optional and an unknown must never travel as a zero. `nutrition`
    /// is already scaled to the amount eaten, so dividing by `amountGrams`
    /// gives the per-100 g figure back.
    static func nutritionPer100g(of entry: FoodEntry) -> WatchFood? {
        guard let grams = entry.amountGrams, grams > 0, grams.isFinite,
              let fibre = entry.nutrition.fiberG else { return nil }
        let facts = entry.nutrition
        func per100(_ value: Double) -> Double { (value * 100 / grams * 100).rounded() / 100 }
        let values = [facts.calories, facts.proteinG, facts.fatG, facts.carbsG, fibre].map(per100)
        guard values.allSatisfy(\.isFinite) else { return nil }
        return WatchFood(name: entry.displayName, kcal: values[0], protein: values[1],
                         fat: values[2], carbs: values[3], fibre: values[4])
    }
}

// MARK: - Foods already stored

/// The one-shot ids of the watch-logged foods this phone has stored, so a
/// `FOOD_LOGGED` that arrives twice is stored once (`handleFoodLogged`).
///
/// `UserDefaults`, newest last, capped: a repeat arrives within seconds (a
/// message and its queued fallback) or, for a `transferUserInfo` the OS
/// replays, within days, and a watch logs a handful of foods a day, so the
/// last 500 cover months.
enum WatchFoodLogReceipts {
    static let defaultsKey = "watchFoodLogReceipts"
    static let capacity = 500

    static func contains(_ id: UUID, in defaults: UserDefaults = .standard) -> Bool {
        (defaults.stringArray(forKey: defaultsKey) ?? []).contains(id.uuidString)
    }

    static func record(_ id: UUID, in defaults: UserDefaults = .standard) {
        var ids = defaults.stringArray(forKey: defaultsKey) ?? []
        guard !ids.contains(id.uuidString) else { return }
        ids.append(id.uuidString)
        defaults.set(Array(ids.suffix(capacity)), forKey: defaultsKey)
    }
}
