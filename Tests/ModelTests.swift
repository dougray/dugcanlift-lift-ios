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
            LiftSchemaV2.models.count,
            "LiftStore.schema must track the newest VersionedSchema"
        )
    }
}
