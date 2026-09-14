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
/// When the shape changes again: add a `V6`, add a stage from `V5` to `V6`,
/// and point `LiftStore.schema` at the new version. Never edit a version that
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
// The same drift risk applies one level down: these frozen classes also
// reference shared VALUE TYPES (`NutritionFacts`, used by FoodEntry, Recipe
// and PlannedMeal alike) by the live, unversioned struct — not a frozen copy.
// A future task that changes `NutritionFacts`'s own shape (a new field, a
// removed one) will silently change what all four frozen shapes above
// declare themselves to be, with nothing in this file touched to reveal it —
// the same "duplicate version checksums" failure this whole enum exists to
// prevent, just triggered from underneath it instead of from a change made
// directly here. Whoever writes `LiftSchemaV6` should check any shared value
// type these frozen models reference for that kind of change too, not just
// the model classes themselves.
enum LiftPreGramServingShapes {

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
            FoodEntry.self,
            BodyMeasurement.self,
            Recipe.self,
            RecipeIngredient.self,
            PlannedMeal.self,
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
            // Unchanged since V5.
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
         LiftSchemaV5.self, LiftSchemaV6.self]
    }

    static var stages: [MigrationStage] {
        [v1ToV2, v2ToV3, v3ToV4, v4ToV5, v5ToV6]
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
}
