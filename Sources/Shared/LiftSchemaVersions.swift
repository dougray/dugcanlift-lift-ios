import Foundation
import SwiftData
import LiftCore

/// Versioned schemas and the migration between them.
///
/// Before COOK there was no migration plan, because there had only ever been
/// one shape of store. Adding the recipe models changed that: a phone with the
/// old store has to be able to open the new one. Without a plan SwiftData has
/// nothing to migrate *from*, and an existing install fails to open its
/// container — which in a release build is a `fatalError` on launch, for every
/// user who already has data.
///
/// **Adding a model is a lightweight migration.** Adding a property to an
/// existing model usually is too, as long as it has a default value — but
/// only if every *older* VersionedSchema that lists that model is pointed at
/// a frozen copy of its pre-change shape, not the live class. Every model
/// type here (`WorkoutDay`, `FoodEntry`, ...) is a single, unversioned Swift
/// class shared across every schema version's `models` array; SwiftData has
/// no idea "V3 saw it before `amountGrams` existed." If a later version's
/// `models` array ends up structurally identical to an earlier one — same
/// types, same properties — SwiftData can no longer tell the two versions
/// apart and refuses to open ANY store: `Duplicate version checksums
/// detected.` See `LiftPreGramServingShapes` below for the pattern: freeze
/// the old shape of whatever model(s) are changing in a dedicated enum, point
/// every version through the one where the change lands at the frozen copy,
/// and only the newest version references the live class. What is not
/// lightweight regardless: renaming, changing a type, or making an existing
/// optional non-optional. Any of those needs a `.custom` stage with a real
/// `willMigrate`/`didMigrate`, not another `.lightweight`.
///
/// When the shape changes again: add a `V8`, add a stage from `V7` to `V8`,
/// and point `LiftStore.schema` at the new version. That includes a change to
/// a struct a model stores, such as `NutritionFacts` — see
/// `LiftPreSaturatedFatShapes`. Never edit a version that
/// has shipped — a store in the wild was written against it. (Freezing an
/// older version's pre-change shape in a `LiftPreGramServingShapes`-style enum
/// is not "editing" it in that sense: the version's meaning and
/// versionIdentifier don't change, only how its already-shipped shape is
/// represented now that the live class has moved on.)

// MARK: - Frozen pre-V5 shapes of FoodEntry / Recipe / RecipeIngredient / PlannedMeal
//
// V5 adds gram-based properties (`amountGrams`, `totalWeightGrams`,
// `snapshotNutritionPerGram`) directly onto the app's existing FoodEntry,
// Recipe and PlannedMeal classes — see NutritionModels.swift/RecipeModels.swift.
// Those classes are shared, unversioned Swift types: V1 through V4 below all
// reference them by `.self` too, which means the moment new stored properties
// land on the live class, V1-V4's *declared* shape silently drifts to match
// V5's, even though nothing in this file changed. With V4 and V5 both then
// listing the exact same 15 model types with the exact same structure,
// SwiftData can no longer tell the two versions apart and refuses to open any
// store at all: `NSInvalidArgumentException: Duplicate version checksums
// detected.` — reproduced against a real on-disk store written by the actual
// pre-V5 binary, not just in a test process.
//
// These frozen copies pin down exactly what V1-V4 actually shipped as —
// without the gram fields — so a real device still on an old build can be
// recognized by checksum and walked forward through v1ToV2 → v2ToV3 → v3ToV4
// → v4ToV5. Only LiftSchemaV1-V4's `models` arrays reference them. Everything
// else in the app, and LiftSchemaV5, keeps using the current
// FoodEntry/Recipe/RecipeIngredient/PlannedMeal directly. RecipeIngredient has
// no property changes of its own, but it must be frozen alongside Recipe
// because its `recipe` relationship is typed to whichever `Recipe` it points
// at, and that type has to be the frozen one to stay inside the same
// (V1-V4) schema graph.
//
// The same drift risk applies one level down, and in V7 it happened: these
// classes originally referenced the live `NutritionFacts` struct, which
// LiftKit 1.9.0 gave an eighth field. SwiftData flattens a struct into one
// column per field, so that silently changed every frozen shape here. They
// now use `LiftPreSaturatedFatShapes.NutritionFacts`, the seven-field copy,
// through the typealias below — see that enum.
enum LiftPreGramServingShapes {

    typealias NutritionFacts = LiftPreSaturatedFatShapes.NutritionFacts

    @Model
    final class FoodEntry {
        var id: UUID = UUID()
        var loggedAt: Date = Date.now
        var dayKey: String = ""

        private var mealTypeRaw: String = MealType.snack.rawValue

        var foodRefID: String = ""
        var name: String = ""
        var brand: String?

        var quantity: Double = 1
        var servingUnit: String = "serving"
        var servingGrams: Double?

        var nutrition: NutritionFacts = NutritionFacts.zero
        var healthKitUUID: UUID?

        init(foodRefID: String, name: String, brand: String? = nil,
             quantity: Double, servingUnit: String, servingGrams: Double? = nil,
             nutrition: NutritionFacts, mealTypeRaw: String, loggedAt: Date = .now) {
            self.id = UUID()
            self.foodRefID = foodRefID
            self.name = name
            self.brand = brand
            self.quantity = quantity
            self.servingUnit = servingUnit
            self.servingGrams = servingGrams
            self.nutrition = nutrition
            self.mealTypeRaw = mealTypeRaw
            self.loggedAt = loggedAt
            self.dayKey = DayKey.make(from: loggedAt)
        }
    }

    @Model
    final class Recipe {
        var id: UUID = UUID()
        var name: String = ""
        var createdAt: Date = Date.now
        var sourceURL: URL?
        var sourceAuthor: String?
        var servings: Double = 1
        var prepMinutes: Int?
        var cookMinutes: Int?
        var steps: [String] = []
        var nutritionPerServing: NutritionFacts?
        var nutritionIsEstimated: Bool = false
        var sourceTranscript: String?

        @Relationship(deleteRule: .cascade, inverse: \RecipeIngredient.recipe)
        var ingredients: [RecipeIngredient]? = []

        init(name: String, servings: Double = 1) {
            self.id = UUID()
            self.name = name
            self.servings = max(servings, 0.0001)
            self.ingredients = []
        }
    }

    @Model
    final class RecipeIngredient {
        var id: UUID = UUID()
        var rawText: String = ""
        var item: String?
        var qty: Double?
        var unit: String?
        var grams: Double?
        var foodRefID: String?
        var isOptional: Bool = false
        var note: String?
        var sortOrder: Int = 0

        var recipe: Recipe?

        init(rawText: String) {
            self.id = UUID()
            self.rawText = rawText
        }
    }

    @Model
    final class PlannedMeal {
        var id: UUID = UUID()
        var dayKey: String = ""
        var plannedFor: Date = Date.now

        private var mealTypeRaw: String = MealType.dinner.rawValue

        var recipeID: UUID = UUID()
        var servings: Double = 1
        var recipeName: String = ""
        var snapshotNutrition: NutritionFacts?
        var loggedFoodEntryID: UUID?

        init(recipeID: UUID, recipeName: String, plannedFor: Date) {
            self.id = UUID()
            self.recipeID = recipeID
            self.recipeName = recipeName
            self.plannedFor = plannedFor
            self.dayKey = DayKey.make(from: plannedFor)
        }
    }
}

// MARK: - Frozen pre-V6 shapes of WorkoutDay / ExerciseEntry / SetEntry
//
// V6 adds `durationSec` and `distanceMeters` to the live `SetEntry` — a set
// can now be 90 seconds or 400 metres, not only a weight for reps, which is
// what CrossFit, Hyrox and endurance focuses need in order to record anything
// at all.
//
// Same drift problem this file's V5 note describes: V1-V5 all listed the live
// `SetEntry` by `.self`, so the moment those two properties land, V5's
// declared shape silently becomes V6's and SwiftData refuses to open any
// store — `Duplicate version checksums detected`. These frozen copies pin
// what V1-V5 actually shipped as.
//
// All three classes are frozen together, not just `SetEntry`. The freeze has
// to close over the relationship graph: `SetEntry.exercise` is typed to
// whichever `ExerciseEntry` it points at, `ExerciseEntry.sets` to whichever
// `SetEntry`, and `ExerciseEntry.day` to whichever `WorkoutDay` — so all
// three have to be the frozen ones to stay inside the same (V1-V5) schema
// graph. This is the same reason `RecipeIngredient` was frozen alongside
// `Recipe` above despite having no property changes of its own.
//
// Per the V5 note's warning about shared value types: none of the three
// reference a shared struct the way FoodEntry references `NutritionFacts`.
// `WorkoutDay.focusRaw` is a plain `String`, so the V6 change to
// `TrainingFocus`'s cases — four to six, matching Android and the browser —
// is not a schema change at all and needs nothing frozen.
enum LiftPreSetMetricsShapes {

    @Model
    final class WorkoutDay {
        var id: UUID = UUID()
        var dayKey: String = ""
        var date: Date = Date.now
        var name: String = ""
        private var focusRaw: String = "bodybuilding"
        var liveStartedAt: Date?
        var liveEndedAt: Date?
        var healthKitUUID: UUID?

        @Relationship(deleteRule: .cascade, inverse: \ExerciseEntry.day)
        var exercises: [ExerciseEntry] = []

        init(date: Date = .now, name: String = "", focusRaw: String = "bodybuilding") {
            self.id = UUID()
            self.date = date
            self.name = name
            self.focusRaw = focusRaw
        }
    }

    @Model
    final class ExerciseEntry {
        var id: UUID = UUID()
        var exerciseRefID: String = ""
        var name: String = ""
        var primaryMuscle: String?
        var equipment: String?
        var orderIndex: Int = 0
        var day: WorkoutDay?

        @Relationship(deleteRule: .cascade, inverse: \SetEntry.exercise)
        var sets: [SetEntry] = []

        init(exerciseRefID: String, name: String, orderIndex: Int,
             primaryMuscle: String? = nil, equipment: String? = nil) {
            self.id = UUID()
            self.exerciseRefID = exerciseRefID
            self.name = name
            self.orderIndex = orderIndex
            self.primaryMuscle = primaryMuscle
            self.equipment = equipment
        }
    }

    @Model
    final class SetEntry {
        var id: UUID = UUID()
        var orderIndex: Int = 0
        var weightKg: Double = 0
        var reps: Int = 0
        var rpe: Double?
        var isWarmup: Bool = false
        var completedAt: Date?
        var exercise: ExerciseEntry?

        init(orderIndex: Int, weightKg: Double = 0, reps: Int = 0,
             rpe: Double? = nil, isWarmup: Bool = false) {
            self.id = UUID()
            self.orderIndex = orderIndex
            self.weightKg = weightKg
            self.reps = reps
            self.rpe = rpe
            self.isWarmup = isWarmup
        }
    }
}

// MARK: - Frozen pre-V7 NutritionFacts, and the V5/V6 classes that store it
//
// V7 is LiftKit 1.9.0's `NutritionFacts.saturatedFatG`. SwiftData does not
// store `NutritionFacts` as a blob: it flattens the struct into one column per
// field on the owning entity (`ZSUGARG`, `ZSODIUMMG`, ... and `ZSUGARG1`, ...
// for PlannedMeal's second one), so a new field in the struct is a new column
// on FoodEntry, Recipe and PlannedMeal, and a new checksum for each.
//
// Every version before V7 declared those entities through the live struct —
// V5 and V6 through the live classes, V1-V4 through LiftPreGramServingShapes,
// whose classes named the live struct too. With the bump alone, none of V1-V6
// matches the store V6 wrote, and staged migration refuses every existing
// install at launch: "Cannot use staged migration with an unknown model
// version" (NSCocoaErrorDomain 134504). Reproduced in LiftKit before this
// change was written; in a release build that is a fatalError on launch, and
// in a DEBUG build LiftStore deletes the store.
//
// The fix is the one this file already uses, one level down. `NutritionFacts`
// below is 1.8.0's struct exactly — seven fields, same names, same order. Its
// type name does not enter the checksum; its fields do. The four classes are
// V5/V6's FoodEntry, Recipe, RecipeIngredient and PlannedMeal as LiftKit 1.8.0
// shipped them, pointed at the frozen struct. RecipeIngredient stores no
// nutrition; it is frozen for the relationship-graph reason given above
// LiftPreSetMetricsShapes.
//
// Never add `saturatedFatG` here or change a field: these must describe the
// store a V6 build wrote. `Tests/Fixtures/v6-store` is such a store, written
// by the V6 binary in a simulator, and `testRealV6StoreOpensAsV7` opens it.
enum LiftPreSaturatedFatShapes {

    /// LiftKit 1.8.0's `NutritionFacts`, field for field.
    struct NutritionFacts: Codable, Hashable, Sendable {
        var calories: Double = 0
        var proteinG: Double = 0
        var carbsG: Double = 0
        var fatG: Double = 0
        var fiberG: Double?
        var sugarG: Double?
        var sodiumMg: Double?

        init(calories: Double = 0,
             proteinG: Double = 0,
             carbsG: Double = 0,
             fatG: Double = 0,
             fiberG: Double? = nil,
             sugarG: Double? = nil,
             sodiumMg: Double? = nil) {
            self.calories = calories
            self.proteinG = proteinG
            self.carbsG = carbsG
            self.fatG = fatG
            self.fiberG = fiberG
            self.sugarG = sugarG
            self.sodiumMg = sodiumMg
        }

        static let zero = NutritionFacts()
    }

    @Model
    final class FoodEntry {
        var id: UUID = UUID()
        var loggedAt: Date = Date.now
        var dayKey: String = ""

        private var mealTypeRaw: String = MealType.snack.rawValue

        var foodRefID: String = ""
        var name: String = ""
        var brand: String?

        var quantity: Double = 1
        var servingUnit: String = "serving"
        var servingGrams: Double?
        var amountGrams: Double?

        var nutrition: NutritionFacts = NutritionFacts.zero
        var healthKitUUID: UUID?

        init(foodRefID: String, name: String, brand: String? = nil,
             quantity: Double, servingUnit: String, servingGrams: Double? = nil,
             amountGrams: Double? = nil,
             nutrition: NutritionFacts, mealTypeRaw: String, loggedAt: Date = .now) {
            self.id = UUID()
            self.foodRefID = foodRefID
            self.name = name
            self.brand = brand
            self.quantity = quantity
            self.servingUnit = servingUnit
            self.servingGrams = servingGrams
            self.amountGrams = amountGrams
            self.nutrition = nutrition
            self.mealTypeRaw = mealTypeRaw
            self.loggedAt = loggedAt
            self.dayKey = DayKey.make(from: loggedAt)
        }
    }

    @Model
    final class Recipe {
        var id: UUID = UUID()
        var name: String = ""
        var createdAt: Date = Date.now
        var sourceURL: URL?
        var sourceAuthor: String?
        var servings: Double = 1
        var prepMinutes: Int?
        var cookMinutes: Int?
        var steps: [String] = []
        var nutritionPerServing: NutritionFacts?
        var nutritionIsEstimated: Bool = false
        var totalWeightGrams: Double?
        var sourceTranscript: String?

        @Relationship(deleteRule: .cascade, inverse: \RecipeIngredient.recipe)
        var ingredients: [RecipeIngredient]? = []

        init(name: String, servings: Double = 1, nutritionPerServing: NutritionFacts? = nil) {
            self.id = UUID()
            self.name = name
            self.servings = max(servings, 0.0001)
            self.nutritionPerServing = nutritionPerServing
            self.ingredients = []
        }
    }

    @Model
    final class RecipeIngredient {
        var id: UUID = UUID()
        var rawText: String = ""
        var item: String?
        var qty: Double?
        var unit: String?
        var grams: Double?
        var foodRefID: String?
        var isOptional: Bool = false
        var note: String?
        var sortOrder: Int = 0

        var recipe: Recipe?

        init(rawText: String) {
            self.id = UUID()
            self.rawText = rawText
        }
    }

    @Model
    final class PlannedMeal {
        var id: UUID = UUID()
        var dayKey: String = ""
        var plannedFor: Date = Date.now

        private var mealTypeRaw: String = MealType.dinner.rawValue

        var recipeID: UUID = UUID()
        var servings: Double = 1
        var recipeName: String = ""
        var snapshotNutrition: NutritionFacts?
        var amountGrams: Double?
        var snapshotNutritionPerGram: NutritionFacts?
        var loggedFoodEntryID: UUID?

        init(recipeID: UUID, recipeName: String, plannedFor: Date,
             snapshotNutrition: NutritionFacts? = nil) {
            self.id = UUID()
            self.recipeID = recipeID
            self.recipeName = recipeName
            self.plannedFor = plannedFor
            self.dayKey = DayKey.make(from: plannedFor)
            self.snapshotNutrition = snapshotNutrition
        }
    }
}

// MARK: - V1 — everything before COOK

enum LiftSchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }

    static var models: [any PersistentModel.Type] {
        [
            LiftPreSetMetricsShapes.WorkoutDay.self,
            LiftPreSetMetricsShapes.ExerciseEntry.self,
            LiftPreSetMetricsShapes.SetEntry.self,
            LiftPreGramServingShapes.FoodEntry.self,
            BodyMeasurement.self
        ]
    }
}

// MARK: - V2 — adds COOK

enum LiftSchemaV2: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(2, 0, 0) }

    static var models: [any PersistentModel.Type] {
        [
            // V1, unchanged.
            LiftPreSetMetricsShapes.WorkoutDay.self,
            LiftPreSetMetricsShapes.ExerciseEntry.self,
            LiftPreSetMetricsShapes.SetEntry.self,
            LiftPreGramServingShapes.FoodEntry.self,
            BodyMeasurement.self,
            // COOK.
            LiftPreGramServingShapes.Recipe.self,
            LiftPreGramServingShapes.RecipeIngredient.self,
            LiftPreGramServingShapes.PlannedMeal.self,
            ShoppingListCheck.self
        ]
    }
}

// MARK: - V3 — adds Routines and imported-plan tracking

enum LiftSchemaV3: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(3, 0, 0) }

    static var models: [any PersistentModel.Type] {
        [
            // V1/V2, unchanged.
            LiftPreSetMetricsShapes.WorkoutDay.self,
            LiftPreSetMetricsShapes.ExerciseEntry.self,
            LiftPreSetMetricsShapes.SetEntry.self,
            LiftPreGramServingShapes.FoodEntry.self,
            BodyMeasurement.self,
            LiftPreGramServingShapes.Recipe.self,
            LiftPreGramServingShapes.RecipeIngredient.self,
            LiftPreGramServingShapes.PlannedMeal.self,
            ShoppingListCheck.self,
            // Routines + plan-link import.
            Routine.self,
            RoutineExercise.self,
            RoutinePrescribedSet.self,
            ImportedPlan.self,
            ScheduledSession.self
        ]
    }
}

// MARK: - V4 — adds outdoor activity recording

enum LiftSchemaV4: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(4, 0, 0) }

    static var models: [any PersistentModel.Type] {
        [
            // V1/V2, unchanged.
            LiftPreSetMetricsShapes.WorkoutDay.self,
            LiftPreSetMetricsShapes.ExerciseEntry.self,
            LiftPreSetMetricsShapes.SetEntry.self,
            LiftPreGramServingShapes.FoodEntry.self,
            BodyMeasurement.self,
            LiftPreGramServingShapes.Recipe.self,
            LiftPreGramServingShapes.RecipeIngredient.self,
            LiftPreGramServingShapes.PlannedMeal.self,
            ShoppingListCheck.self,
            // V3, unchanged.
            Routine.self,
            RoutineExercise.self,
            RoutinePrescribedSet.self,
            ImportedPlan.self,
            ScheduledSession.self,
            // Route recording.
            OutdoorActivity.self
        ]
    }
}

// MARK: - V5 — adds gram-based serving measurement

enum LiftSchemaV5: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(5, 0, 0) }

    static var models: [any PersistentModel.Type] {
        [
            // V1/V2, unchanged.
            LiftPreSetMetricsShapes.WorkoutDay.self,
            LiftPreSetMetricsShapes.ExerciseEntry.self,
            LiftPreSetMetricsShapes.SetEntry.self,
            LiftPreSaturatedFatShapes.FoodEntry.self,
            BodyMeasurement.self,
            LiftPreSaturatedFatShapes.Recipe.self,
            LiftPreSaturatedFatShapes.RecipeIngredient.self,
            LiftPreSaturatedFatShapes.PlannedMeal.self,
            ShoppingListCheck.self,
            // V3, unchanged.
            Routine.self,
            RoutineExercise.self,
            RoutinePrescribedSet.self,
            ImportedPlan.self,
            ScheduledSession.self,
            // V4, unchanged.
            OutdoorActivity.self
        ]
    }
}

// MARK: - V6 — a set can be time or distance, not only weight for reps

enum LiftSchemaV6: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(6, 0, 0) }

    static var models: [any PersistentModel.Type] {
        [
            // The three that changed — live classes, with durationSec and
            // distanceMeters on SetEntry.
            WorkoutDay.self,
            ExerciseEntry.self,
            SetEntry.self,
            // Unchanged since V5 — frozen, because V7 changes the
            // NutritionFacts they store.
            LiftPreSaturatedFatShapes.FoodEntry.self,
            BodyMeasurement.self,
            LiftPreSaturatedFatShapes.Recipe.self,
            LiftPreSaturatedFatShapes.RecipeIngredient.self,
            LiftPreSaturatedFatShapes.PlannedMeal.self,
            ShoppingListCheck.self,
            Routine.self,
            RoutineExercise.self,
            RoutinePrescribedSet.self,
            ImportedPlan.self,
            ScheduledSession.self,
            OutdoorActivity.self
        ]
    }
}

// MARK: - V7 — saturated fat (LiftKit 1.9.0's NutritionFacts.saturatedFatG)

enum LiftSchemaV7: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(7, 0, 0) }

    static var models: [any PersistentModel.Type] {
        [
            WorkoutDay.self,
            ExerciseEntry.self,
            SetEntry.self,
            // The four that changed — live classes, whose NutritionFacts
            // columns now include saturatedFatG. RecipeIngredient has none of
            // its own; it follows Recipe through the relationship.
            FoodEntry.self,
            BodyMeasurement.self,
            Recipe.self,
            RecipeIngredient.self,
            PlannedMeal.self,
            ShoppingListCheck.self,
            Routine.self,
            RoutineExercise.self,
            RoutinePrescribedSet.self,
            ImportedPlan.self,
            ScheduledSession.self,
            OutdoorActivity.self
        ]
    }
}

// MARK: - Plan

enum LiftMigrationPlan: SchemaMigrationPlan {

    static var schemas: [any VersionedSchema.Type] {
        [LiftSchemaV1.self, LiftSchemaV2.self, LiftSchemaV3.self, LiftSchemaV4.self,
         LiftSchemaV5.self, LiftSchemaV6.self, LiftSchemaV7.self]
    }

    static var stages: [MigrationStage] {
        [v1ToV2, v2ToV3, v3ToV4, v4ToV5, v5ToV6, v6ToV7]
    }

    /// Four new model types and no change to any existing one, so SwiftData can
    /// do this itself. Existing rows are untouched.
    static let v1ToV2 = MigrationStage.lightweight(
        fromVersion: LiftSchemaV1.self,
        toVersion: LiftSchemaV2.self
    )

    /// Five new model types (Routine, RoutineExercise, RoutinePrescribedSet,
    /// ImportedPlan, ScheduledSession) and no change to any existing one —
    /// lightweight per this file's own rule above.
    static let v2ToV3 = MigrationStage.lightweight(
        fromVersion: LiftSchemaV2.self,
        toVersion: LiftSchemaV3.self
    )

    /// One new model type (OutdoorActivity) and no change to any existing
    /// one — lightweight per this file's own rule above.
    static let v3ToV4 = MigrationStage.lightweight(
        fromVersion: LiftSchemaV3.self,
        toVersion: LiftSchemaV4.self
    )

    /// New optional properties on FoodEntry (amountGrams), Recipe
    /// (totalWeightGrams), and PlannedMeal (amountGrams,
    /// snapshotNutritionPerGram) — no new model types, no renames, no type
    /// changes, no optional-to-non-optional changes. Lightweight per this
    /// file's own rule above.
    static let v4ToV5 = MigrationStage.lightweight(
        fromVersion: LiftSchemaV4.self,
        toVersion: LiftSchemaV5.self
    )

    /// Two new optional properties on SetEntry (durationSec, distanceMeters) —
    /// no new model types, no renames, no type changes, no optional-to-
    /// non-optional changes. Lightweight per this file's own rule above, and
    /// V1-V5 are pointed at LiftPreSetMetricsShapes so their checksums still
    /// describe the store those builds actually wrote.
    ///
    /// TrainingFocus gaining `hyrox`, `endurance` and `everything` is not part
    /// of this stage: `focusRaw` is a String column and an unrecognised value
    /// already falls back rather than failing, which is how days written as
    /// `conditioning` keep working.
    static let v5ToV6 = MigrationStage.lightweight(
        fromVersion: LiftSchemaV5.self,
        toVersion: LiftSchemaV6.self
    )

    /// One new optional column, `saturatedFatG`, wherever a `NutritionFacts`
    /// is stored: FoodEntry, Recipe, and PlannedMeal twice. No new model
    /// types, no renames, no type changes. Existing rows read nil, which means
    /// "the source did not say" — never zero. V1-V6 are pointed at
    /// LiftPreSaturatedFatShapes so their checksums still describe the stores
    /// those builds wrote.
    static let v6ToV7 = MigrationStage.lightweight(
        fromVersion: LiftSchemaV6.self,
        toVersion: LiftSchemaV7.self
    )
}
