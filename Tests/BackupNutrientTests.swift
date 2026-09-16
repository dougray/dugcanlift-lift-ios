import XCTest
import SwiftData
import LiftCore
@testable import Lift

/// Saturated fat, sugar and sodium in the backup file — coach/BACKUP-FORMAT.md
/// `food[]` and a recipe's `nutritionPerServing`.
///
/// `ios-backup-nutrients.json` is LIFT web's fixture for an older iPhone file
/// that carried sugar and sodium only under `ext.ios`, copied unchanged from
/// dugcanlift-site/lift/fixtures so both builds pin the same fallback.
/// `android-backup-nutrients.json` is hand-written in the shape LIFT Android
/// and web write the common fields (field names from Android's
/// BackupStoreNutrientTest); neither encoder produced it, so it proves the
/// names and the nil rules, not byte-for-byte agreement.
final class BackupNutrientTests: XCTestCase {

    override func setUp() {
        super.setUp()
        clearDefaults()
    }

    override func tearDown() {
        clearDefaults()
        super.tearDown()
    }

    private func clearDefaults() {
        UserDefaults.standard.removeObject(forKey: BackupStore.foreignDataKey)
        UserDefaults.standard.removeObject(forKey: BackupStore.foreignExtKey)
    }

    private func makeContext() -> ModelContext {
        ModelContext(LiftStore.makeContainer(inMemory: true))
    }

    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "json"),
                                "fixture \(name).json is not in the test bundle")
        return try Data(contentsOf: url)
    }

    private func root(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - Writing

    func testAFoodsThreeAreWrittenUnderTheirCommonNames() throws {
        let context = makeContext()
        context.insert(FoodEntry(foodRefID: "usda:1", name: "Soup", quantity: 1, servingUnit: "serving",
                                 nutrition: NutritionFacts(calories: 200, proteinG: 8, carbsG: 25, fatG: 6,
                                                           sugarG: 5, sodiumMg: 890.4, saturatedFatG: 2.45),
                                 mealType: .lunch))
        context.insert(FoodEntry(foodRefID: "usda:2", name: "Oats", quantity: 1, servingUnit: "serving",
                                 nutrition: NutritionFacts(calories: 300, proteinG: 10, carbsG: 50, fatG: 5),
                                 mealType: .breakfast))
        try context.save()

        let file = try root(try BackupStore.build(context: context))
        let food = try XCTUnwrap((file["data"] as? [String: Any])?["food"] as? [[String: Any]])
        let soup = try XCTUnwrap(food.first { $0["name"] as? String == "Soup" })
        XCTAssertEqual(soup["saturatedFatG"] as? Double, 2.45, "unrounded: a backup is built to be restored")
        XCTAssertEqual(soup["sugarG"] as? Double, 5)
        XCTAssertEqual(soup["sodiumMg"] as? Double, 890.4)

        let oats = try XCTUnwrap(food.first { $0["name"] as? String == "Oats" })
        XCTAssertNil(oats["saturatedFatG"], "unknown is left out, never written as zero")
        XCTAssertNil(oats["sugarG"])
        XCTAssertNil(oats["sodiumMg"])
    }

    func testARecipesAndAPlannedMealsNutritionCarryThem() throws {
        let context = makeContext()
        let recipe = Recipe(name: "Chilli", servings: 4,
                            nutritionPerServing: NutritionFacts(calories: 450, proteinG: 36, carbsG: 30, fatG: 18,
                                                                sodiumMg: 800, saturatedFatG: 6))
        context.insert(recipe)
        context.insert(PlannedMeal(recipe: recipe, mealType: .dinner, plannedFor: .now, servings: 2))
        try context.save()

        let data = try XCTUnwrap(try root(try BackupStore.build(context: context))["data"] as? [String: Any])
        let nutrition = try XCTUnwrap((data["recipes"] as? [[String: Any]])?.first?["nutritionPerServing"] as? [String: Any])
        XCTAssertEqual(nutrition["saturatedFatG"] as? Double, 6)
        XCTAssertEqual(nutrition["sodiumMg"] as? Double, 800)
        XCTAssertNil(nutrition["sugarG"])

        let snapshot = try XCTUnwrap((data["plan"] as? [[String: Any]])?.first?["snapshotNutrition"] as? [String: Any])
        XCTAssertEqual(snapshot["saturatedFatG"] as? Double, 6, "per serving, like the snapshot's macros")
    }

    /// An iPhone that has not updated yet reads sugar and sodium only from
    /// ext.ios, so they are still written there too.
    func testSugarAndSodiumAreStillWrittenForAnOlderIPhone() throws {
        let context = makeContext()
        let entry = FoodEntry(foodRefID: "usda:1", name: "Soup", quantity: 1, servingUnit: "serving",
                              nutrition: NutritionFacts(calories: 200, sugarG: 5, sodiumMg: 890, saturatedFatG: 2),
                              mealType: .lunch)
        context.insert(entry)
        try context.save()

        let ext = try XCTUnwrap(try root(try BackupStore.build(context: context))["ext"] as? [String: Any])
        let extras = try XCTUnwrap(((ext["ios"] as? [String: Any])?["food"] as? [String: Any])?[entry.id.uuidString] as? [String: Any])
        XCTAssertEqual(extras["sugarG"] as? Double, 5)
        XCTAssertEqual(extras["sodiumMg"] as? Double, 890)
        XCTAssertNil(extras["saturatedFatG"], "the common field is the only home for anything new")
    }

    func testAllThreeSurviveARoundTrip() throws {
        let source = makeContext()
        let facts = NutritionFacts(calories: 200, proteinG: 8, carbsG: 25, fatG: 6,
                                   sugarG: 5.5, sodiumMg: 890, saturatedFatG: 2.4)
        let entry = FoodEntry(foodRefID: "usda:1", name: "Soup", quantity: 1, servingUnit: "serving",
                              nutrition: facts, mealType: .lunch)
        source.insert(entry)
        source.insert(Recipe(name: "Chilli", servings: 4, nutritionPerServing: facts))
        try source.save()

        let target = makeContext()
        _ = BackupStore.restore(context: target, from: try BackupStore.build(context: source))
        XCTAssertEqual(try target.fetch(FetchDescriptor<FoodEntry>()).first?.nutrition.saturatedFatG, 2.4)
        XCTAssertEqual(try target.fetch(FetchDescriptor<FoodEntry>()).first?.nutrition.sugarG, 5.5)
        XCTAssertEqual(try target.fetch(FetchDescriptor<Recipe>()).first?.nutritionPerServing?.saturatedFatG, 2.4)
        XCTAssertEqual(try target.fetch(FetchDescriptor<Recipe>()).first?.nutritionPerServing?.sodiumMg, 890)
    }

    // MARK: - Reading another build's file

    func testAnAndroidOrWebShapedFileRestoresTheCommonFields() throws {
        let context = makeContext()
        _ = BackupStore.restore(context: context, from: try fixture("android-backup-nutrients"))

        let food = try context.fetch(FetchDescriptor<FoodEntry>())
        let soup = try XCTUnwrap(food.first { $0.name == "Tomato soup" })
        XCTAssertEqual(soup.nutrition.saturatedFatG, 2.4)
        XCTAssertEqual(soup.nutrition.sugarG, 5)
        XCTAssertEqual(soup.nutrition.sodiumMg, 890)

        let oats = try XCTUnwrap(food.first { $0.name == "Rolled oats" })
        XCTAssertNil(oats.nutrition.saturatedFatG, "absent is not recorded")
        XCTAssertNil(oats.nutrition.sugarG)
        XCTAssertNil(oats.nutrition.sodiumMg)

        let cola = try XCTUnwrap(food.first { $0.name == "Cola" })
        XCTAssertEqual(cola.nutrition.saturatedFatG, 0, "a recorded zero is a value")
        XCTAssertNil(cola.nutrition.sodiumMg, "null is not recorded, never zero")

        let chilli = try XCTUnwrap(try context.fetch(FetchDescriptor<Recipe>()).first)
        XCTAssertEqual(chilli.nutritionPerServing?.saturatedFatG, 6)
        XCTAssertEqual(chilli.nutritionPerServing?.sodiumMg, 800)
        XCTAssertNil(chilli.nutritionPerServing?.sugarG)
    }

    func testAnOlderIPhoneFilesSugarAndSodiumComeFromExtWhenTheCommonFieldIsMissing() throws {
        let context = makeContext()
        _ = BackupStore.restore(context: context, from: try fixture("ios-backup-nutrients"))

        let food = try context.fetch(FetchDescriptor<FoodEntry>())
        let granola = try XCTUnwrap(food.first { $0.name == "Granola" })
        XCTAssertEqual(granola.nutrition.sugarG, 18.5)
        XCTAssertEqual(granola.nutrition.sodiumMg, 0, "a recorded zero is a value")
        XCTAssertNil(granola.nutrition.saturatedFatG, "iOS never recorded saturated fat")

        let juice = try XCTUnwrap(food.first { $0.name == "Orange juice" })
        XCTAssertEqual(juice.nutrition.sugarG, 21, "the common field wins over ext.ios")
        XCTAssertEqual(juice.nutrition.sodiumMg, 2, "and ext.ios still fills the one that is missing")

        let egg = try XCTUnwrap(food.first { $0.name == "Egg" })
        XCTAssertNil(egg.nutrition.sugarG)
        XCTAssertNil(egg.nutrition.sodiumMg)

        let recipes = try context.fetch(FetchDescriptor<Recipe>())
        let soup = try XCTUnwrap(recipes.first { $0.name == "Tomato soup" })
        XCTAssertEqual(soup.nutritionPerServing?.sugarG, 11)
        XCTAssertEqual(soup.nutritionPerServing?.sodiumMg, 640)
        XCTAssertNil(try XCTUnwrap(recipes.first { $0.name == "Unmeasured stew" }).nutritionPerServing,
                     "no macros, nowhere to hold them")
    }

    /// The real iPhone file from before the common fields, which web and
    /// Android also test against.
    func testTheShippedIPhoneRecipeFileStillRestoresSugarAndSodium() throws {
        let context = makeContext()
        _ = BackupStore.restore(context: context, from: try fixture("ios-backup-recipes"))
        let facts = try XCTUnwrap(try context.fetch(FetchDescriptor<Recipe>()).first?.nutritionPerServing)
        XCTAssertEqual(facts.sugarG, 9)
        XCTAssertEqual(facts.sodiumMg, 410)
        XCTAssertNil(facts.saturatedFatG)
    }
}
