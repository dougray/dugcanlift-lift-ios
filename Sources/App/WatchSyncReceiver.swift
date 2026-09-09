import Foundation
import WatchConnectivity
import SwiftData
import WidgetKit

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

    init(context: ModelContext) {
        self.context = context
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
        case .sessionFinished, .workoutEdited, .workoutSyncAck, .outdoorActivityFinished:
            return false // no phone-side handler yet for these
        }
    }

    @MainActor
    @discardableResult
    private func handleFoodLogged(_ envelope: SyncEnvelope) async -> Bool {
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
        try? context.save()
        WidgetCenter.shared.reloadAllTimelines()
        pushRecentFoodsSnapshot()
        return true
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
        let items = recent.map {
            RecentFoodsSnapshot.Item(foodRefID: $0.foodRefID, displayName: $0.displayName, lastAmountGrams: $0.amountGrams)
        }
        let snapshot = RecentFoodsSnapshot(items: items, generatedAt: .now)
        guard let dict = try? snapshot.messageBody() else { return }
        try? WCSession.default.updateApplicationContext(dict)
    }
}
