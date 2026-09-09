import XCTest
import SwiftData
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
        let sut = WatchSyncReceiver(context: context)
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

        let sut = WatchSyncReceiver(context: context)
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
        let sut = WatchSyncReceiver(context: context)
        let envelope = foodLoggedEnvelope(foodRefID: "not-a-real-ref-id")

        let handled = await sut.handle(envelope)

        XCTAssertFalse(handled)
        let entries = try context.fetch(FetchDescriptor<FoodEntry>())
        XCTAssertTrue(entries.isEmpty)
    }

    func testUnknownMealTypeIsSilentlyDroppedWithoutInserting() async throws {
        let context = makeContext()
        let sut = WatchSyncReceiver(context: context)
        let envelope = foodLoggedEnvelope(foodRefID: "usda:174608", meal: "brunch")

        let handled = await sut.handle(envelope)

        XCTAssertFalse(handled)
        let entries = try context.fetch(FetchDescriptor<FoodEntry>())
        XCTAssertTrue(entries.isEmpty)
    }

    func testMissingFoodLogPayloadIsSilentlyDroppedWithoutInserting() async throws {
        let context = makeContext()
        let sut = WatchSyncReceiver(context: context)
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
        let sut = WatchSyncReceiver(context: context)
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
