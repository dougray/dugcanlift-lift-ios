import XCTest
import SwiftData
@testable import Lift

final class NutritionFactsTests: XCTestCase {

    func testAdditionSumsMacros() {
        let a = NutritionFacts(calories: 100, proteinG: 10, carbsG: 5, fatG: 2)
        let b = NutritionFacts(calories: 250, proteinG: 20, carbsG: 30, fatG: 8)
        let total = a + b

        XCTAssertEqual(total.calories, 350)
        XCTAssertEqual(total.proteinG, 30)
        XCTAssertEqual(total.carbsG, 35)
        XCTAssertEqual(total.fatG, 10)
    }

    func testMissingFibreStaysMissing() {
        let a = NutritionFacts(calories: 100, proteinG: 0, carbsG: 0, fatG: 0)
        let b = NutritionFacts(calories: 100, proteinG: 0, carbsG: 0, fatG: 0)
        XCTAssertNil((a + b).fiberG, "nil + nil must not become 0")
    }

    func testPartialFibreIsPreserved() {
        var a = NutritionFacts(calories: 100, proteinG: 0, carbsG: 0, fatG: 0)
        a.fiberG = 3
        let b = NutritionFacts(calories: 100, proteinG: 0, carbsG: 0, fatG: 0)
        XCTAssertEqual((a + b).fiberG, 3)
    }

    func testScaling() {
        let base = NutritionFacts(calories: 100, proteinG: 10, carbsG: 5, fatG: 2)
        let scaled = base.scaled(by: 1.5)
        XCTAssertEqual(scaled.calories, 150)
        XCTAssertEqual(scaled.proteinG, 15)
    }
}

final class WorkoutMathTests: XCTestCase {

    func testWarmupSetsAreExcludedFromVolume() {
        let working = SetEntry(orderIndex: 0, weightKg: 50, reps: 10)
        let warmup = SetEntry(orderIndex: 1, weightKg: 20, reps: 10, isWarmup: true)

        XCTAssertEqual(working.volumeKg, 500)
        XCTAssertEqual(warmup.volumeKg, 0)
    }

    func testEpleyEstimate() {
        let set = SetEntry(orderIndex: 0, weightKg: 100, reps: 5)
        XCTAssertEqual(set.estimatedOneRepMaxKg ?? 0, 116.67, accuracy: 0.01)
    }

    func testNoEstimateForWarmups() {
        let set = SetEntry(orderIndex: 0, weightKg: 100, reps: 5, isWarmup: true)
        XCTAssertNil(set.estimatedOneRepMaxKg)
    }

    func testUnitConversionRoundTrips() {
        let kg = 102.5
        let lb = WeightUnit.pounds.fromKilograms(kg)
        XCTAssertEqual(WeightUnit.pounds.toKilograms(lb), kg, accuracy: 0.0001)
    }
}

final class DayKeyTests: XCTestCase {

    func testKeyIsStableAcrossTimeZones() {
        let date = Date(timeIntervalSince1970: 1_754_500_000)
        let austin = DayKey.make(from: date, timeZone: TimeZone(identifier: "America/Chicago")!)
        let tokyo = DayKey.make(from: date, timeZone: TimeZone(identifier: "Asia/Tokyo")!)

        XCTAssertEqual(austin.count, 10)
        XCTAssertNotEqual(austin, tokyo, "A fixed instant falls on different local days")
    }

    func testFormat() {
        let date = Date(timeIntervalSince1970: 0)
        let key = DayKey.make(from: date, timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertEqual(key, "1970-01-01")
    }
}

// MARK: - Migration

/// Proves an existing store survives the COOK models being added.
///
/// This is the failure that has no second chance: a phone with a V1 store opens
/// a V2 build, and if the migration cannot be applied the container throws. In
/// DEBUG that deletes the store; in a release build it is a `fatalError` on
/// launch for everyone who already had data. So the migration is exercised
/// against a real file on disk, not asserted about.
final class SchemaMigrationTests: XCTestCase {

    private var storeURL: URL!

    override func setUpWithError() throws {
        storeURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("migration-\(UUID().uuidString).store")
    }

    override func tearDownWithError() throws {
        for suffix in ["", "-shm", "-wal"] {
            try? FileManager.default.removeItem(
                at: URL(fileURLWithPath: storeURL.path + suffix))
        }
    }

    func testV1StoreOpensAsV2WithDataIntact() throws {
        let loggedAt = Date(timeIntervalSince1970: 1_756_000_000)
        let dayKey = DayKey.make(from: loggedAt)

        // Write a store using only the pre-COOK models.
        do {
            let v1 = try ModelContainer(
                for: Schema(versionedSchema: LiftSchemaV1.self),
                configurations: [ModelConfiguration(url: storeURL)]
            )
            let context = ModelContext(v1)
            context.insert(FoodEntry(
                foodRefID: "usda:174608",
                name: "Oats",
                quantity: 2,
                servingUnit: "serving",
                nutrition: NutritionFacts(calories: 300, proteinG: 10, carbsG: 54, fatG: 5),
                mealType: .breakfast,
                loggedAt: loggedAt
            ))
            try context.save()
        }

        // Reopen it the way the app does.
        let v2 = try ModelContainer(
            for: Schema(versionedSchema: LiftSchemaV2.self),
            migrationPlan: LiftMigrationPlan.self,
            configurations: [ModelConfiguration(url: storeURL)]
        )
        let context = ModelContext(v2)

        let food = try context.fetch(FetchDescriptor<FoodEntry>())
        XCTAssertEqual(food.count, 1, "the V1 entry must survive the migration")
        XCTAssertEqual(food.first?.name, "Oats")
        XCTAssertEqual(food.first?.dayKey, dayKey)
        XCTAssertEqual(food.first?.nutrition.calories, 300)

        // And the new models must be usable in the migrated store.
        let recipe = Recipe(name: "Overnight oats", servings: 2)
        context.insert(recipe)
        try context.save()
        XCTAssertEqual(try context.fetch(FetchDescriptor<Recipe>()).count, 1)
    }

    func testCurrentSchemaIsTheNewestVersion() {
        XCTAssertEqual(
            LiftStore.schema.entities.count,
            LiftSchemaV3.models.count,
            "LiftStore.schema must track the newest VersionedSchema"
        )
    }
}

/// The two platforms must agree on what time dinner is. If these thresholds
/// drift from Android's `mealForHour`, the same food re-logged at the same time
/// lands in a different meal on each, and a coach reading the log sees a
/// difference that isn't real.
final class MealForHourTests: XCTestCase {

    func testMatchesAndroidThresholds() {
        XCTAssertEqual(MealType.forHour(0),  .breakfast)
        XCTAssertEqual(MealType.forHour(10), .breakfast)
        XCTAssertEqual(MealType.forHour(11), .lunch)
        XCTAssertEqual(MealType.forHour(14), .lunch)
        XCTAssertEqual(MealType.forHour(15), .dinner)
        XCTAssertEqual(MealType.forHour(20), .dinner)
        XCTAssertEqual(MealType.forHour(21), .snack)
        XCTAssertEqual(MealType.forHour(23), .snack)
    }
}

/// The ingredient parser is deliberately small, so what matters is that it
/// gives up cleanly rather than guessing. A confident wrong quantity on a
/// shopping list is worse than a line the reader can see and check.
final class IngredientParserTests: XCTestCase {

    func testParsesQuantityUnitAndItem() {
        let parsed = IngredientParser.parse("2 tbsp olive oil", sortOrder: 0)
        XCTAssertEqual(parsed.qty, 2)
        XCTAssertEqual(parsed.unit, "tbsp")
        XCTAssertEqual(parsed.item, "olive oil")
    }

    func testGramsAreResolvedForMacroLookup() {
        XCTAssertEqual(IngredientParser.parse("400 g chicken thigh", sortOrder: 0).grams, 400)
        XCTAssertNil(IngredientParser.parse("2 tbsp olive oil", sortOrder: 0).grams,
                     "only grams resolve to a mass")
    }

    func testCountsGetTheSentinelNotAUnit() {
        let parsed = IngredientParser.parse("2 eggs", sortOrder: 0)
        XCTAssertEqual(parsed.qty, 2)
        XCTAssertEqual(parsed.item, "eggs")
        XCTAssertEqual(parsed.unit, IngredientParser.countUnit)
    }

    /// The sentinel must be something nobody can type, or a real ingredient
    /// measured in it would be silently treated as a count.
    func testSentinelCannotCollideWithTypedText() {
        XCTAssertTrue(IngredientParser.countUnit.contains("\u{0000}"))
    }

    func testFractions() {
        XCTAssertEqual(IngredientParser.parse("1/2 cup rice", sortOrder: 0).qty, 0.5)
        XCTAssertEqual(IngredientParser.parse("1 1/2 cups rice", sortOrder: 0).qty, 1.5)
        XCTAssertEqual(IngredientParser.parse("0.5 kg beef", sortOrder: 0).qty, 0.5)
    }

    func testUnparseableLinesKeepTheirRawTextAndNothingElse() {
        let parsed = IngredientParser.parse("salt to taste", sortOrder: 3)
        XCTAssertEqual(parsed.rawText, "salt to taste")
        XCTAssertNil(parsed.item, "a line that did not parse must not invent an item")
        XCTAssertNil(parsed.qty)
        XCTAssertEqual(parsed.sortOrder, 3)
    }

    func testRawTextIsKeptEvenWhenTheParseSucceeds() {
        XCTAssertEqual(
            IngredientParser.parse("2 tbsp olive oil", sortOrder: 0).rawText,
            "2 tbsp olive oil"
        )
    }

    /// Two cloves of garlic must never be added to two cups of anything.
    func testCountsAndUnitsStayInSeparateBuckets() {
        let recipe = Recipe(name: "Test", servings: 1)
        let garlicCloves = IngredientParser.parse("2 cloves garlic", sortOrder: 0)
        let garlicGrams = IngredientParser.parse("30 g garlic", sortOrder: 1)
        garlicCloves.recipe = recipe
        garlicGrams.recipe = recipe
        recipe.ingredients = [garlicCloves, garlicGrams]

        let meal = PlannedMeal(recipe: recipe, mealType: .dinner, plannedFor: .now)
        let lines = ShoppingList.build(from: [meal], recipes: [recipe.id: recipe])

        XCTAssertEqual(lines.count, 1, "same item name, one line")
        XCTAssertEqual(lines.first?.amounts.count, 2, "but two units, kept apart")
        XCTAssertEqual(lines.first?.amounts["cloves"], 2)
        XCTAssertEqual(lines.first?.amounts["g"], 30)
    }
}

/// `PlannedMeal.snapshotNutrition` is per serving on both platforms.
///
/// Storing it pre-scaled renders correctly and is still wrong: the moment a
/// plan travels between clients, one side is off by a factor of `servings` and
/// nothing looks broken enough to notice. Android already stores per serving;
/// these tests stop iOS drifting away from it again.
final class PlannedMealNutritionTests: XCTestCase {

    private func recipe(calories: Double, servings: Double) -> Recipe {
        Recipe(
            name: "Test",
            servings: servings,
            nutritionPerServing: NutritionFacts(
                calories: calories, proteinG: 10, carbsG: 20, fatG: 5
            )
        )
    }

    func testSnapshotIsStoredPerServingNotScaled() {
        let meal = PlannedMeal(
            recipe: recipe(calories: 300, servings: 1),
            mealType: .dinner,
            plannedFor: .now,
            servings: 2
        )
        XCTAssertEqual(meal.snapshotNutrition?.calories, 300,
                       "the snapshot must be per serving, not multiplied by servings")
    }

    func testScaledNutritionMultipliesByServings() {
        let meal = PlannedMeal(
            recipe: recipe(calories: 300, servings: 1),
            mealType: .dinner,
            plannedFor: .now,
            servings: 2
        )
        XCTAssertEqual(meal.scaledNutrition?.calories, 600)
        XCTAssertEqual(meal.scaledNutrition?.proteinG, 20)
    }

    /// `FoodEntry.nutrition` is already-scaled by contract, so a two-serving
    /// dinner must log the full amount — not one serving, and not four.
    func testLoggedEntryCarriesTheScaledAmount() {
        let meal = PlannedMeal(
            recipe: recipe(calories: 300, servings: 1),
            mealType: .dinner,
            plannedFor: .now,
            servings: 2
        )
        let entry = meal.makeFoodEntry()
        XCTAssertEqual(entry?.nutrition.calories, 600)
        XCTAssertEqual(entry?.quantity, 2)
        XCTAssertEqual(entry?.foodRefID, "recipe:\(meal.recipeID.uuidString)")
    }

    func testNoMacrosMeansNoEntryRatherThanAZeroCalorieDinner() {
        let bare = Recipe(name: "Unknown", servings: 1)
        let meal = PlannedMeal(recipe: bare, mealType: .dinner, plannedFor: .now, servings: 2)
        XCTAssertNil(meal.scaledNutrition)
        XCTAssertNil(meal.makeFoodEntry())
    }
}
