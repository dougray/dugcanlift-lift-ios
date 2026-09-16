import XCTest
import SwiftData
import LiftCore
@testable import Lift

/// Recipes and the meal plan in the backup file, against coach/BACKUP-FORMAT.md.
///
/// The interop tests decode files the other LIFT builds wrote with their own
/// code: `web-backup-recipes.json` from LIFT web's saveBackup, and
/// `android-backup-recipes.json` from LIFT Android's BackupStore.build. They are
/// the only tests here that prove this app reads what the others write rather
/// than agreeing with itself. Do not regenerate them from this code.
final class BackupRecipesTests: XCTestCase {

    override func setUp() {
        super.setUp()
        clearDefaults()
    }

    override func tearDown() {
        clearDefaults()
        super.tearDown()
    }

    /// `restore` keeps preserved sections in UserDefaults, which outlives a test.
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

    private func file(_ data: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["v": 1, "app": "lift", "saved": "2026-09-16", "data": data])
    }

    // MARK: - Interop

    func testAWebBackupRestoresItsRecipeAndPlannedMeal() throws {
        let context = makeContext()
        let result = BackupStore.restore(context: context, from: try fixture("web-backup-recipes"))
        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.added, 2, "one recipe and one planned meal")

        let recipe = try XCTUnwrap(try context.fetch(FetchDescriptor<Recipe>()).first)
        XCTAssertEqual(recipe.name, "Beef Chilli")
        XCTAssertEqual(recipe.servings, 4)
        XCTAssertEqual(recipe.nutritionPerServing?.fiberG, 9)
        XCTAssertEqual(recipe.steps, ["Brown the beef", "Simmer for an hour"])

        let lines = (recipe.ingredients ?? []).sorted { $0.sortOrder < $1.sortOrder }
        XCTAssertEqual(lines.map(\.rawText),
                       ["500 g lean beef mince", "2 tins chopped tomatoes", "1 tbsp olive oil", "salt to taste"])
        XCTAssertEqual(lines[0].grams, 500)
        XCTAssertNil(lines[3].qty, "a line that does not parse carries no quantity")

        let meal = try XCTUnwrap(try context.fetch(FetchDescriptor<PlannedMeal>()).first)
        XCTAssertEqual(meal.recipeID, recipe.id, "the lower-case recipeId finds the recipe")
        XCTAssertEqual(meal.dayKey, "2026-09-17")
        XCTAssertEqual(meal.mealType, .dinner, "DINNER in the file, lower case on iOS")
        XCTAssertEqual(meal.servings, 2)
        XCTAssertEqual(meal.snapshotNutrition?.calories, 520)
        XCTAssertNil(meal.loggedFoodEntryID)
    }

    func testAnAndroidBackupRestoresAWeighedRecipeAndAGramBasedMeal() throws {
        let context = makeContext()
        let result = BackupStore.restore(context: context, from: try fixture("android-backup-recipes"))
        XCTAssertEqual(result.added, 3, "one recipe and two planned meals")

        let recipe = try XCTUnwrap(try context.fetch(FetchDescriptor<Recipe>()).first)
        XCTAssertEqual(recipe.totalWeightGrams, 600)
        XCTAssertTrue(recipe.nutritionIsEstimated, "nutrition-level `estimated` is recipe-level on iOS")
        XCTAssertEqual(recipe.sourceURL?.absoluteString, "https://example.com/oats")
        XCTAssertEqual(recipe.prepMinutes, 5)

        let meals = try context.fetch(FetchDescriptor<PlannedMeal>())
        let byGrams = try XCTUnwrap(meals.first { $0.amountGrams != nil })
        XCTAssertEqual(byGrams.amountGrams, 250)
        XCTAssertEqual(byGrams.snapshotNutritionPerGram?.calories ?? 0, 1.2933, accuracy: 0.0001)
        XCTAssertEqual(byGrams.mealType, .breakfast)
    }

    /// Android writes `routines`, which this app does not store. Before sections
    /// were preserved, restoring an Android backup here and saving again dropped
    /// every routine.
    func testAndroidsRoutinesSurviveARestoreAndSave() throws {
        let context = makeContext()
        _ = BackupStore.restore(context: context, from: try fixture("android-backup-recipes"))
        let saved = try JSONSerialization.jsonObject(with: try BackupStore.build(context: context)) as? [String: Any]
        let data = try XCTUnwrap(saved?["data"] as? [String: Any])
        XCTAssertNotNil(data["routines"])
    }

    // MARK: - Round trip

    func testARecipeAndItsPlanSurviveARoundTripWithTheirIOSOnlyFields() throws {
        let source = makeContext()
        let recipe = Recipe(name: "Chilli", servings: 4,
                            steps: ["Brown", "Simmer"],
                            nutritionPerServing: NutritionFacts(calories: 520, proteinG: 38, carbsG: 30,
                                                                fatG: 24, fiberG: 9, sugarG: 7, sodiumMg: 640),
                            nutritionIsEstimated: true)
        recipe.totalWeightGrams = 1200
        source.insert(recipe)
        let beef = IngredientParser.parse("500 g beef mince", sortOrder: 0)
        beef.foodRefID = "usda:174036"
        beef.recipe = recipe
        source.insert(beef)
        let salt = IngredientParser.parse("salt to taste", sortOrder: 1)
        salt.isOptional = true
        salt.recipe = recipe
        source.insert(salt)
        let plannedFor = Date(timeIntervalSince1970: 1_789_700_000)
        source.insert(PlannedMeal(recipe: recipe, mealType: .dinner, plannedFor: plannedFor, servings: 2))
        try source.save()

        let target = makeContext()
        let result = BackupStore.restore(context: target, from: try BackupStore.build(context: source))
        XCTAssertEqual(result.added, 2)

        let restored = try XCTUnwrap(try target.fetch(FetchDescriptor<Recipe>()).first)
        XCTAssertEqual(restored.id, recipe.id)
        XCTAssertEqual(restored.totalWeightGrams, 1200)
        XCTAssertEqual(restored.nutritionPerServing?.sugarG, 7, "sugar travels in the common field, and under ext.ios for an older iPhone")
        XCTAssertEqual(restored.nutritionPerServing?.sodiumMg, 640)
        XCTAssertTrue(restored.nutritionIsEstimated)
        let lines = (restored.ingredients ?? []).sorted { $0.sortOrder < $1.sortOrder }
        XCTAssertEqual(lines[0].foodRefID, "usda:174036", "foodRefID travels under ext.ios by position")
        XCTAssertTrue(lines[1].isOptional)

        let meal = try XCTUnwrap(try target.fetch(FetchDescriptor<PlannedMeal>()).first)
        XCTAssertEqual(meal.plannedFor, plannedFor)
        XCTAssertEqual(meal.servings, 2)
        XCTAssertEqual(meal.snapshotNutrition?.calories, 520)
    }

    func testRestoringTheSameFileTwiceAddsNothingTheSecondTime() throws {
        let context = makeContext()
        _ = BackupStore.restore(context: context, from: try fixture("web-backup-recipes"))
        let again = BackupStore.restore(context: context, from: try fixture("web-backup-recipes"))
        XCTAssertEqual(again.added, 0)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Recipe>()).count, 1)
    }

    // MARK: - The rules

    /// The browser falls back to a non-UUID id without crypto.randomUUID. Such a
    /// recipe used to be skipped, orphaning every meal pointing at it.
    func testANonUUIDRecipeIdRestoresAndKeepsItsMeal() throws {
        let context = makeContext()
        let result = BackupStore.restore(context: context, from: try file([
            "recipes": [["id": "1726500000000.123", "name": "Oats", "servings": 1]],
            "plan": [["id": "1726500000001.456", "recipeId": "1726500000000.123",
                      "date": "2026-09-18", "meal": "BREAKFAST", "servings": 1]]
        ]))
        XCTAssertEqual(result.added, 2)
        let recipe = try XCTUnwrap(try context.fetch(FetchDescriptor<Recipe>()).first)
        let meal = try XCTUnwrap(try context.fetch(FetchDescriptor<PlannedMeal>()).first)
        XCTAssertEqual(meal.recipeID, recipe.id, "the meal's recipeId derives to the same UUID")
    }

    func testTheDerivedIdIsStable() {
        XCTAssertEqual(BackupStore.recordID("1726500000000.123"), BackupStore.recordID("1726500000000.123"))
        XCTAssertNotEqual(BackupStore.recordID("1726500000000.123"), BackupStore.recordID("1726500000000.124"))
        XCTAssertNil(BackupStore.recordID(""))
        XCTAssertNil(BackupStore.recordID(nil))
    }

    func testANonUUIDFoodEntryIsNoLongerSkipped() throws {
        let context = makeContext()
        let result = BackupStore.restore(context: context, from: try file([
            "food": [["id": "1726500000000.9", "name": "Oats", "date": "2026-09-16", "servings": 1,
                      "calories": 300, "proteinG": 10, "fatG": 5, "carbsG": 50, "meal": "BREAKFAST"]]
        ]))
        XCTAssertEqual(result.added, 1)
    }

    func testAPlannedMealWhoseRecipeExistsNowhereIsSkipped() throws {
        let context = makeContext()
        let result = BackupStore.restore(context: context, from: try file([
            "plan": [["id": "4601600a-ae05-4e47-9d68-279195ec24da", "recipeId": "a7991786-a81d-438b-8f2a-5e5b822c865a",
                      "date": "2026-09-17", "meal": "DINNER", "servings": 1]]
        ]))
        XCTAssertEqual(result.added, 0)
        XCTAssertTrue(try context.fetch(FetchDescriptor<PlannedMeal>()).isEmpty)
    }

    func testAnUnknownSectionSurvivesAndShoppingTicksDoNot() throws {
        let context = makeContext()
        _ = BackupStore.restore(context: context, from: try file([
            "futureSection": ["keep me"],
            "shopping": ["beef mince"]
        ]))
        let saved = try JSONSerialization.jsonObject(with: try BackupStore.build(context: context)) as? [String: Any]
        let data = try XCTUnwrap(saved?["data"] as? [String: Any])
        XCTAssertEqual(data["futureSection"] as? [String], ["keep me"])
        XCTAssertNil(data["shopping"])
    }

    /// A preserved copy of a section this app stores must never replace the
    /// phone's own data on save.
    func testAPreservedCopyCannotOverwriteThisAppsRecipes() throws {
        let context = makeContext()
        context.insert(Recipe(name: "Mine", servings: 1))
        try context.save()
        let stale = try JSONSerialization.data(withJSONObject: ["recipes": [["id": "x", "name": "Stale"]]])
        UserDefaults.standard.set(stale, forKey: BackupStore.foreignDataKey)

        let saved = try JSONSerialization.jsonObject(with: try BackupStore.build(context: context)) as? [String: Any]
        let recipes = try XCTUnwrap((saved?["data"] as? [String: Any])?["recipes"] as? [[String: Any]])
        XCTAssertEqual(recipes.map { $0["name"] as? String }, ["Mine"])
    }
}
