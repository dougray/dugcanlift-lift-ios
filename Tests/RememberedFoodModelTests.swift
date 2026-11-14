import XCTest
import SwiftData
import LiftCore
@testable import Lift

final class RememberedFoodModelTests: XCTestCase {
    private var storeURL: URL!

    override func setUp() {
        storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("v9to10-\(UUID().uuidString).store")
    }
    override func tearDown() {
        for suffix in ["", "-shm", "-wal"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: storeURL.path + suffix))
        }
    }

    func testAV9StoreOpensAsV10WithItsFoodIntact() throws {
        do {
            let v9 = try ModelContainer(for: Schema(versionedSchema: LiftSchemaV9.self),
                                        configurations: [ModelConfiguration(url: storeURL)])
            let context = ModelContext(v9)
            context.insert(FoodEntry(foodRefID: "usda:174608", name: "Oats", brand: nil,
                                     quantity: 40, servingUnit: "g", amountGrams: 40,
                                     nutrition: NutritionFacts(calories: 150, proteinG: 5, carbsG: 27, fatG: 3),
                                     mealType: .breakfast))
            try context.save()
        }
        let v10 = try ModelContainer(for: Schema(versionedSchema: LiftSchemaV10.self),
                                     migrationPlan: LiftMigrationPlan.self,
                                     configurations: [ModelConfiguration(url: storeURL)])
        let context = ModelContext(v10)
        let food = try context.fetch(FetchDescriptor<FoodEntry>())
        XCTAssertEqual(food.map(\.name), ["Oats"])
        XCTAssertEqual(food.first?.nutrition.calories, 150)
        XCTAssertEqual(try context.fetch(FetchDescriptor<RememberedFood>()).count, 0)

        context.insert(RememberedFood(code: "36000291452", name: "Corn flakes",
                                      per100g: NutritionFacts(calories: 357, proteinG: 7, carbsG: 84, fatG: 0.4)))
        try context.save()
        XCTAssertEqual(try context.fetch(FetchDescriptor<RememberedFood>()).first?.name, "Corn flakes")
    }

    func testABlankOptionalNutrientStaysNilThroughTheStore() throws {
        let context = ModelContext(LiftStore.makeContainer(inMemory: true))
        context.insert(RememberedFood(code: "4006381333931", name: "Pencil-shaped snack",
                                      per100g: NutritionFacts(calories: 400, proteinG: 10, carbsG: 60, fatG: 12)))
        try context.save()
        let back = try XCTUnwrap(context.fetch(FetchDescriptor<RememberedFood>()).first)
        XCTAssertNil(back.per100g.fiberG)
        XCTAssertNil(back.per100g.sodiumMg)
    }

}

/// V10 -> V11: three new optional columns on `OutdoorActivity` -- a run's
/// average and max heart rate, and where they came from. Written through
/// `LiftPreRunHeartRateShapes`, which is what V4-V10 declared, so this is the
/// shape a V10 build wrote.
final class RunHeartRateSchemaTests: XCTestCase {
    private var storeURL: URL!

    override func setUp() {
        storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("v10to11-\(UUID().uuidString).store")
    }
    override func tearDown() {
        for suffix in ["", "-shm", "-wal"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: storeURL.path + suffix))
        }
    }

    func testAV10StoreOpensAsV11WithItsRunIntactAndNoHeartRate() throws {
        let id: UUID
        let healthKitID = UUID()
        let start = Date(timeIntervalSince1970: 1_789_500_000)
        let points = [
            RoutePoint(latitude: 47.6, longitude: -122.3, altitudeMeters: 20, recordedAt: start,
                       horizontalAccuracyMeters: 5, verticalAccuracyMeters: 4),
            RoutePoint(latitude: 47.61, longitude: -122.31, altitudeMeters: 25,
                       recordedAt: start.addingTimeInterval(30),
                       horizontalAccuracyMeters: 8, verticalAccuracyMeters: 6)
        ]
        do {
            let v10 = try ModelContainer(for: Schema(versionedSchema: LiftSchemaV10.self),
                                         configurations: [ModelConfiguration(url: storeURL)])
            let context = ModelContext(v10)
            let run = LiftPreRunHeartRateShapes.OutdoorActivity(activityType: .run, startedAt: start)
            run.endedAt = start.addingTimeInterval(1800)
            run.distanceMeters = 5012.5
            run.elevationGainMeters = 41.5
            run.activeCalories = 350
            run.routePointsData = try JSONEncoder().encode(points)
            run.healthKitUUID = healthKitID
            context.insert(run)
            id = run.id
            try context.save()
        }

        let v11 = try ModelContainer(for: Schema(versionedSchema: LiftSchemaV11.self),
                                     migrationPlan: LiftMigrationPlan.self,
                                     configurations: [ModelConfiguration(url: storeURL)])
        let context = ModelContext(v11)
        let run = try XCTUnwrap(context.fetch(FetchDescriptor<OutdoorActivity>()).first)
        XCTAssertEqual(run.id, id)
        XCTAssertEqual(run.activityType, .run)
        XCTAssertEqual(run.startedAt, start)
        XCTAssertEqual(run.endedAt, start.addingTimeInterval(1800))
        XCTAssertEqual(run.distanceMeters, 5012.5)
        XCTAssertEqual(run.elevationGainMeters, 41.5)
        XCTAssertEqual(run.activeCalories, 350)
        XCTAssertEqual(run.routePoints, points)
        XCTAssertEqual(run.healthKitUUID, healthKitID)
        XCTAssertNil(run.averageBpm, "a run recorded before heart rate had none, not zero")
        XCTAssertNil(run.maxBpm)
        XCTAssertNil(run.heartRateSource)

        // And the new columns take a value in the migrated store.
        run.averageBpm = 141
        run.maxBpm = 168
        run.heartRateSource = "Polar H10"
        try context.save()
        let back = try XCTUnwrap(context.fetch(FetchDescriptor<OutdoorActivity>()).first)
        XCTAssertEqual(back.averageBpm, 141)
        XCTAssertEqual(back.maxBpm, 168)
        XCTAssertEqual(back.heartRateSource, "Polar H10")
    }
}
