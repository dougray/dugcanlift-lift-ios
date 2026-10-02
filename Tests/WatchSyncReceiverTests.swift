import XCTest
import SwiftData
import LiftCore
import LiftSync
@testable import Lift

/// `WatchSyncReceiver` is the phone's landing point for every
/// `SyncEnvelope` the watch sends. These tests drive `handle(_:)` directly
/// (the `internal` entry point `deliver` funnels into after decoding a raw
/// `WCSession` message dictionary) rather than going through `WCSession`
/// itself — there is no way to simulate a real cross-device message in a
/// unit test, and `deliver`'s only real job beyond decoding is exactly what
/// `SyncEnvelopeTests` already pins down.
final class WatchSyncReceiverTests: XCTestCase {

    private func makeContext() -> ModelContext {
        let container = LiftStore.makeContainer(inMemory: true)
        return ModelContext(container)
    }

    /// Its own `UserDefaults` suite per test, so food receipts never land in
    /// the test host's real defaults. Every receiver built here also gets a
    /// sender that goes nowhere: the test host is LIFT itself, whose
    /// `WCSession` is really activated on a simulator paired with a watch,
    /// and acknowledgements sent from a test would reach that watch.
    private func isolatedDefaults(_ name: String = #function) -> UserDefaults {
        let suite = "WatchSyncReceiverTests.\(name)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    private func foodLoggedEnvelope(
        foodRefID: String = "usda:174608",
        amountGrams: Double = 150,
        meal: String = "lunch",
        loggedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> SyncEnvelope {
        SyncEnvelope(
            event: .foodLogged,
            workoutID: UUID(),
            revision: 1,
            updatedAt: loggedAt,
            origin: .watchOS,
            foodLog: FoodLogPayload(
                foodRefID: foodRefID,
                amountGrams: amountGrams,
                meal: meal,
                loggedAt: loggedAt
            )
        )
    }

    // MARK: - Well-formed .foodLogged

    /// "usda:174608" is the same real `food.db` fixture used by
    /// `FoodRefResolverTests` and `RecentFoodsQueryTests` — Chicken breast,
    /// roll, oven-roasted, 134.0 kcal/100g.
    func testFoodLoggedInsertsFoodEntryWithResolvedNutrition() async throws {
        let context = makeContext()
        let sut = WatchSyncReceiver(context: context, defaults: isolatedDefaults(), sender: { _ in })
        let envelope = foodLoggedEnvelope(foodRefID: "usda:174608", amountGrams: 150, meal: "lunch")

        let handled = await sut.handle(envelope)

        XCTAssertTrue(handled)
        let entries = try context.fetch(FetchDescriptor<FoodEntry>())
        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entry.foodRefID, "usda:174608")
        XCTAssertEqual(entry.amountGrams, 150)
        XCTAssertEqual(entry.mealType, .lunch)
        XCTAssertEqual(entry.name, "Chicken breast, roll, oven-roasted")
        XCTAssertEqual(entry.nutrition.calories, 201.0, accuracy: 0.01)
        XCTAssertEqual(entry.loggedAt, envelope.foodLog?.loggedAt)
    }

    func testFoodLoggedResolvesRecipeRef() async throws {
        let context = makeContext()
        let recipe = Recipe(
            name: "Chicken Stir Fry",
            nutritionPerServing: NutritionFacts(
                calories: 400, proteinG: 30, carbsG: 20, fatG: 15,
                fiberG: 4, sugarG: 6, sodiumMg: 600
            )
        )
        recipe.totalWeightGrams = 800
        context.insert(recipe)
        try context.save()

        let sut = WatchSyncReceiver(context: context, defaults: isolatedDefaults(), sender: { _ in })
        let envelope = foodLoggedEnvelope(foodRefID: recipe.foodRefID, amountGrams: 200, meal: "dinner")

        let handled = await sut.handle(envelope)

        XCTAssertTrue(handled)
        let entries = try context.fetch(FetchDescriptor<FoodEntry>())
        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry.name, "Chicken Stir Fry")
        XCTAssertEqual(entry.mealType, .dinner)
        XCTAssertEqual(entry.nutrition.calories, 100.0, accuracy: 0.01)
    }

    // MARK: - Malformed / unresolvable envelopes are dropped silently

    func testUnknownFoodRefIDIsSilentlyDroppedWithoutInserting() async throws {
        let context = makeContext()
        let sut = WatchSyncReceiver(context: context, defaults: isolatedDefaults(), sender: { _ in })
        let envelope = foodLoggedEnvelope(foodRefID: "not-a-real-ref-id")

        let handled = await sut.handle(envelope)

        XCTAssertFalse(handled)
        let entries = try context.fetch(FetchDescriptor<FoodEntry>())
        XCTAssertTrue(entries.isEmpty)
    }

    func testUnknownMealTypeIsSilentlyDroppedWithoutInserting() async throws {
        let context = makeContext()
        let sut = WatchSyncReceiver(context: context, defaults: isolatedDefaults(), sender: { _ in })
        let envelope = foodLoggedEnvelope(foodRefID: "usda:174608", meal: "brunch")

        let handled = await sut.handle(envelope)

        XCTAssertFalse(handled)
        let entries = try context.fetch(FetchDescriptor<FoodEntry>())
        XCTAssertTrue(entries.isEmpty)
    }

    func testMissingFoodLogPayloadIsSilentlyDroppedWithoutInserting() async throws {
        let context = makeContext()
        let sut = WatchSyncReceiver(context: context, defaults: isolatedDefaults(), sender: { _ in })
        // event is .foodLogged but foodLog itself is nil — malformed on the
        // wire, but SyncEnvelope's own decoding still lets it construct.
        let envelope = SyncEnvelope(
            event: .foodLogged,
            workoutID: UUID(),
            revision: 1,
            updatedAt: .now,
            origin: .watchOS,
            foodLog: nil
        )

        let handled = await sut.handle(envelope)

        XCTAssertFalse(handled)
        let entries = try context.fetch(FetchDescriptor<FoodEntry>())
        XCTAssertTrue(entries.isEmpty)
    }

    // MARK: - Non-food events are no-ops today

    func testNonFoodEventIsANoOp() async throws {
        let context = makeContext()
        let sut = WatchSyncReceiver(context: context, defaults: isolatedDefaults(), sender: { _ in })
        let envelope = SyncEnvelope(
            event: .sessionFinished,
            workoutID: UUID(),
            revision: 1,
            updatedAt: .now,
            origin: .watchOS
        )

        let handled = await sut.handle(envelope)

        XCTAssertFalse(handled)
        let entries = try context.fetch(FetchDescriptor<FoodEntry>())
        XCTAssertTrue(entries.isEmpty)
    }

    // MARK: - A finished session

    private func sessionEnvelope(id: UUID = UUID(), revision: Int = 2,
                                 reps: Int = 5) -> SyncEnvelope {
        let started = Date(timeIntervalSince1970: 1_789_891_200)
        return SyncEnvelope(
            event: .sessionFinished,
            workoutID: id,
            revision: revision,
            updatedAt: started,
            origin: .watchOS,
            session: FinishedSession(
                name: "Upper A",
                performedOn: DayKey.make(from: started),
                startedAt: started,
                finishedAt: started.addingTimeInterval(3600),
                exercises: [PerformedExercise(
                    name: "Bulgarian Split Squat", equipment: "dumbbell",
                    sets: [PerformedSet(weightKg: 30, reps: reps, rpe: 8, side: .left)]
                )]
            ),
            heartRate: SessionHeartRate(averageBpm: 128.5, maxBpm: 171)
        )
    }

    /// The acknowledgement is what lets the watch stop offering the session,
    /// exactly as it is for a food. Until it arrives the watch holds the
    /// only other copy.
    func testAStoredSessionIsAcknowledgedUnderItsOwnID() async throws {
        let context = makeContext()
        var sent: [SyncEnvelope] = []
        let sut = WatchSyncReceiver(context: context, defaults: isolatedDefaults(),
                                    sender: { sent.append($0) })
        let envelope = sessionEnvelope()

        let handled = await sut.handle(envelope)

        XCTAssertTrue(handled)
        let day = try XCTUnwrap(try context.fetch(FetchDescriptor<WorkoutDay>()).first)
        XCTAssertEqual(day.orderedExercises.first?.orderedSets.first?.side, .left)
        let ack = try XCTUnwrap(sent.first { $0.event == .workoutSyncAck })
        XCTAssertEqual(ack.workoutID, envelope.workoutID)
        XCTAssertEqual(ack.revision, envelope.revision)
        XCTAssertEqual(ack.origin, .ios)
    }

    /// A resend, or a queued copy arriving after the live one: stored once,
    /// acknowledged both times, because the first acknowledgement may be the
    /// thing that was lost.
    func testTheSameSessionArrivingTwiceIsStoredOnceAndAcknowledgedTwice() async throws {
        let context = makeContext()
        var sent: [SyncEnvelope] = []
        let sut = WatchSyncReceiver(context: context, defaults: isolatedDefaults(),
                                    sender: { sent.append($0) })
        let envelope = sessionEnvelope()

        _ = await sut.handle(envelope)
        _ = await sut.handle(envelope)

        let days = try context.fetch(FetchDescriptor<WorkoutDay>())
        XCTAssertEqual(days.count, 1)
        XCTAssertEqual(days.first?.totalSetCount, 1)
        XCTAssertEqual(sent.filter { $0.event == .workoutSyncAck }.map(\.workoutID),
                       [envelope.workoutID, envelope.workoutID])
    }

    /// Heart rate still travels with it, and is still kept beside the store
    /// rather than on the day.
    func testTheSessionsHeartRateIsRecorded() async throws {
        let context = makeContext()
        let defaults = isolatedDefaults()
        let sut = WatchSyncReceiver(context: context, defaults: defaults, sender: { _ in })
        let envelope = sessionEnvelope()

        _ = await sut.handle(envelope)

        let stored = try XCTUnwrap(WatchSessionHeartRateStore.latest(in: defaults))
        XCTAssertEqual(stored.workoutID, envelope.workoutID)
        XCTAssertEqual(stored.maxBpm, 171)
    }

    // MARK: - Phone -> watch mapping (WatchSyncReceiver.makeSnapshot)

    /// The pure mapping half of `pushRecentFoodsSnapshot()`. The
    /// `activationState == .activated` guard in that method never passes in
    /// a unit test process (no real `WCSession` activates here), so this is
    /// the only way to exercise it — and it's the exact contract the
    /// not-yet-started watch-side plan will build against.
    func testMakeSnapshotMapsBrandPrefixedDisplayName() throws {
        let entry = FoodEntry(
            foodRefID: "off:3017620422003",
            name: "Nutella",
            brand: "Ferrero",
            quantity: 15,
            servingUnit: "g",
            amountGrams: 15,
            nutrition: NutritionFacts(calories: 80, proteinG: 1, carbsG: 8.7, fatG: 4.6),
            mealType: .snack
        )

        let snapshot = WatchSyncReceiver.makeSnapshot(from: [entry], generatedAt: Date(timeIntervalSince1970: 1_700_000_000))

        let item = try XCTUnwrap(snapshot.items.first)
        XCTAssertEqual(item.foodRefID, "off:3017620422003")
        XCTAssertEqual(item.displayName, "Ferrero Nutella")
        XCTAssertEqual(item.lastAmountGrams, 15)
        XCTAssertEqual(snapshot.generatedAt, Date(timeIntervalSince1970: 1_700_000_000))
    }

    /// A legacy entry logged before `amountGrams` existed (or where
    /// migration couldn't determine a gram equivalent) must map to
    /// `lastAmountGrams: nil`, never a guessed value.
    func testMakeSnapshotMapsLegacyEntryWithNilAmountGramsToNilLastAmountGrams() throws {
        let legacyEntry = FoodEntry(
            foodRefID: "usda:174608",
            name: "Chicken breast, roll, oven-roasted",
            quantity: 1,
            servingUnit: "serving",
            amountGrams: nil,
            nutrition: NutritionFacts(calories: 201, proteinG: 21.885, carbsG: 2.685, fatG: 11.475),
            mealType: .lunch
        )

        let snapshot = WatchSyncReceiver.makeSnapshot(from: [legacyEntry])

        let item = try XCTUnwrap(snapshot.items.first)
        XCTAssertNil(item.lastAmountGrams)
        XCTAssertEqual(item.foodRefID, "usda:174608")
    }

    /// `makeSnapshot` itself does no capping — respecting `limit` is
    /// `RecentFoodsQuery.recent(context:limit:)`'s job, already covered by
    /// `RecentFoodsQueryTests`. `pushRecentFoodsSnapshot()`'s own `limit: 20`
    /// argument can't be exercised directly: it's gated behind
    /// `WCSession.activationState == .activated`, which never passes in a
    /// unit test process. What we *can* pin here is that composing the two
    /// — feeding an already-capped `RecentFoodsQuery.recent` result into
    /// `makeSnapshot` — produces a snapshot with exactly that many items,
    /// in the same order, so the seam between them is type- and
    /// count-correct even though the real caller is untestable.
    func testMakeSnapshotPreservesCountAndOrderOfAlreadyCappedRecentFoodsQueryResult() throws {
        let context = makeContext()
        for index in 0..<25 {
            let entry = FoodEntry(
                foodRefID: "usda:\(index)",
                name: "Food \(index)",
                quantity: 100,
                servingUnit: "g",
                amountGrams: 100,
                nutrition: NutritionFacts(calories: 100, proteinG: 1, carbsG: 1, fatG: 1),
                mealType: .snack,
                loggedAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(index))
            )
            context.insert(entry)
        }
        try context.save()

        let recent = RecentFoodsQuery.recent(context: context, limit: 20)
        let snapshot = WatchSyncReceiver.makeSnapshot(from: recent)

        XCTAssertEqual(snapshot.items.count, 20)
        // Newest first: index 24 was logged last.
        XCTAssertEqual(snapshot.items.first?.foodRefID, "usda:24")
    }

    /// A legacy/migrated `FoodEntry` with no `foodRefID` (the field defaults
    /// to `""`, see `NutritionModels.swift`) must never reach the watch: the
    /// watch has no way to distinguish it from a real, resolvable ref, so it
    /// renders as a normal tappable row — tapping it and logging silently
    /// does nothing, because `FoodRefResolver.nutrition(for: "", ...)`
    /// resolves to `nil` and `handleFoodLogged` drops the request with no
    /// user-visible feedback. Filtering it out here is cheaper and more
    /// honest than letting the watch offer something it can't act on.
    func testMakeSnapshotExcludesEntriesWithEmptyFoodRefID() throws {
        let resolvable = FoodEntry(
            foodRefID: "usda:174608",
            name: "Chicken breast, roll, oven-roasted",
            quantity: 1,
            servingUnit: "serving",
            amountGrams: 140,
            nutrition: NutritionFacts(calories: 201, proteinG: 21.885, carbsG: 2.685, fatG: 11.475),
            mealType: .lunch
        )
        let legacyWithNoRef = FoodEntry(
            foodRefID: "",
            name: "Homemade Soup",
            quantity: 1,
            servingUnit: "bowl",
            amountGrams: nil,
            nutrition: NutritionFacts(calories: 150, proteinG: 5, carbsG: 20, fatG: 4),
            mealType: .dinner
        )

        let snapshot = WatchSyncReceiver.makeSnapshot(from: [resolvable, legacyWithNoRef])

        XCTAssertEqual(snapshot.items.count, 1)
        XCTAssertEqual(snapshot.items.first?.foodRefID, "usda:174608")
    }

    // MARK: - Stored once, and acknowledged


    /// The acknowledgement is what takes the food out of the watch's
    /// standalone log, so a later export does not count it twice.
    func testAStoredFoodIsAcknowledgedUnderItsOwnID() async throws {
        let context = makeContext()
        var sent: [SyncEnvelope] = []
        let sut = WatchSyncReceiver(context: context, defaults: isolatedDefaults(),
                                    sender: { sent.append($0) })
        let envelope = foodLoggedEnvelope()

        let handled = await sut.handle(envelope)

        XCTAssertTrue(handled)
        let ack = try XCTUnwrap(sent.first { $0.event == .workoutSyncAck })
        XCTAssertEqual(ack.workoutID, envelope.workoutID)
        XCTAssertEqual(ack.revision, envelope.revision)
        XCTAssertEqual(ack.origin, .ios)
        XCTAssertNil(ack.foodLog)
    }

    /// The watch sends by `sendMessage` and falls back to `transferUserInfo`
    /// on an error, and an error does not prove the message was lost. The
    /// same food arriving twice is one entry, acknowledged both times.
    func testTheSameFoodArrivingTwiceIsStoredOnce() async throws {
        let context = makeContext()
        var sent: [SyncEnvelope] = []
        let sut = WatchSyncReceiver(context: context, defaults: isolatedDefaults(),
                                    sender: { sent.append($0) })
        let envelope = foodLoggedEnvelope()

        let first = await sut.handle(envelope)
        let second = await sut.handle(envelope)

        XCTAssertTrue(first)
        XCTAssertTrue(second)
        XCTAssertEqual(try context.fetch(FetchDescriptor<FoodEntry>()).count, 1)
        XCTAssertEqual(sent.filter { $0.event == .workoutSyncAck }.map(\.workoutID),
                       [envelope.workoutID, envelope.workoutID])
    }

    /// The message and its queued fallback can arrive together, and storing
    /// a food awaits the reference database. Both copies arriving while the
    /// first is still being resolved must still make one entry.
    func testTwoCopiesArrivingTogetherAreStoredOnce() async throws {
        let context = makeContext()
        let sut = WatchSyncReceiver(context: context, defaults: isolatedDefaults(), sender: { _ in })
        let envelope = foodLoggedEnvelope()

        async let first = sut.handle(envelope)
        async let second = sut.handle(envelope)
        let results = await [first, second]

        XCTAssertEqual(results, [true, true])
        XCTAssertEqual(try context.fetch(FetchDescriptor<FoodEntry>()).count, 1)
    }

    /// Two different foods, even identical portions of the same one, are
    /// two entries: only the id makes a repeat.
    func testTwoFoodsWithTheSameContentAreBothStored() async throws {
        let context = makeContext()
        let sut = WatchSyncReceiver(context: context, defaults: isolatedDefaults(), sender: { _ in })

        _ = await sut.handle(foodLoggedEnvelope())
        _ = await sut.handle(foodLoggedEnvelope())

        XCTAssertEqual(try context.fetch(FetchDescriptor<FoodEntry>()).count, 2)
    }

    /// Not stored, not acknowledged: the watch keeps the food exportable.
    func testAFoodThatCannotBeStoredIsNotAcknowledged() async throws {
        var sent: [SyncEnvelope] = []
        let sut = WatchSyncReceiver(context: makeContext(), defaults: isolatedDefaults(),
                                    sender: { sent.append($0) })

        let handled = await sut.handle(foodLoggedEnvelope(foodRefID: "usda:does-not-exist"))

        XCTAssertFalse(handled)
        XCTAssertTrue(sent.isEmpty)
    }

    func testReceiptsAreCappedOldestFirst() {
        let defaults = isolatedDefaults()
        let ids = (0...WatchFoodLogReceipts.capacity).map { _ in UUID() }
        for id in ids { WatchFoodLogReceipts.record(id, in: defaults) }
        XCTAssertFalse(WatchFoodLogReceipts.contains(ids[0], in: defaults))
        XCTAssertTrue(WatchFoodLogReceipts.contains(ids[1], in: defaults))
        XCTAssertTrue(WatchFoodLogReceipts.contains(ids.last!, in: defaults))
    }

    // MARK: - Per-100 g macros for the watch's own food log

    /// 150 g of the `usda:174608` fixture, as `handleFoodLogged` stores it:
    /// `nutrition` scaled to the amount eaten. Per 100 g that is the
    /// database's own 134 kcal row back again.
    func testMakeSnapshotCarriesMacrosPer100Grams() throws {
        let entry = FoodEntry(
            foodRefID: "usda:174608",
            name: "Chicken breast, roll, oven-roasted",
            quantity: 150,
            servingUnit: "g",
            amountGrams: 150,
            nutrition: NutritionFacts(calories: 201, proteinG: 21.885, carbsG: 2.685,
                                      fatG: 11.475, fiberG: 0.15),
            mealType: .lunch
        )
        let item = try XCTUnwrap(WatchSyncReceiver.makeSnapshot(from: [entry]).items.first)
        let macros = try XCTUnwrap(item.nutritionPer100g)
        XCTAssertEqual(macros.name, "Chicken breast, roll, oven-roasted")
        XCTAssertEqual(macros.kcal, 134, accuracy: 0.001)
        XCTAssertEqual(macros.protein, 14.59, accuracy: 0.001)
        XCTAssertEqual(macros.carbs, 1.79, accuracy: 0.001)
        XCTAssertEqual(macros.fat, 7.65, accuracy: 0.001)
        XCTAssertEqual(macros.fibre, 0.1, accuracy: 0.001)
        // ...and the watch reads them under the name it shows.
        XCTAssertEqual(item.watchFood?.kcal, macros.kcal)
    }

    /// No gram amount to divide by: no macros, rather than a guess.
    func testMakeSnapshotOmitsMacrosWithoutAGramAmount() throws {
        let entry = FoodEntry(
            foodRefID: "usda:174608", name: "Chicken breast, roll, oven-roasted",
            quantity: 1, servingUnit: "serving", amountGrams: nil,
            nutrition: NutritionFacts(calories: 201, proteinG: 21.885, carbsG: 2.685,
                                      fatG: 11.475, fiberG: 0.15),
            mealType: .lunch
        )
        XCTAssertNil(WatchSyncReceiver.makeSnapshot(from: [entry]).items.first?.nutritionPer100g)
    }

    /// Fibre unknown: `WatchFood.fibre` cannot say so, and a zero would be a
    /// made-up number in an export, so the macros are left out entirely.
    func testMakeSnapshotOmitsMacrosWhenFibreIsUnknown() throws {
        let entry = FoodEntry(
            foodRefID: "off:3017620422003", name: "Nutella", brand: "Ferrero",
            quantity: 15, servingUnit: "g", amountGrams: 15,
            nutrition: NutritionFacts(calories: 80, proteinG: 1, carbsG: 8.7, fatG: 4.6),
            mealType: .snack
        )
        XCTAssertNil(WatchSyncReceiver.makeSnapshot(from: [entry]).items.first?.nutritionPer100g)
    }

    // MARK: - Message-dictionary decoding path (deliver's own responsibility)

    /// Exercises the same `SyncEnvelope(messageBody:)` decode that
    /// `deliver` uses on a real `WCSession` payload, including the
    /// ISO-8601 date strings the wire format actually carries (a plain
    /// `JSONDecoder()` without `.iso8601` would fail on these).
    func testMessageBodyRoundTripsThroughSyncEnvelopeDecoding() throws {
        let envelope = foodLoggedEnvelope()
        let body = try envelope.messageBody()

        let decoded = try SyncEnvelope(messageBody: body)

        XCTAssertEqual(decoded, envelope)
    }
}
