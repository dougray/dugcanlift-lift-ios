import Foundation
import SwiftData

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
/// existing model usually is too, as long as it has a default value. What is
/// not lightweight: renaming, changing a type, or making an existing optional
/// non-optional. Any of those needs a `.custom` stage with a real
/// `willMigrate`/`didMigrate`, not another `.lightweight`.
///
/// When the shape changes again: add a `V3`, add a stage from `V2` to `V3`,
/// and point `LiftStore.schema` at the new version. Never edit a version that
/// has shipped — a store in the wild was written against it.

// MARK: - V1 — everything before COOK

enum LiftSchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }

    static var models: [any PersistentModel.Type] {
        [
            WorkoutDay.self,
            ExerciseEntry.self,
            SetEntry.self,
            FoodEntry.self,
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
            WorkoutDay.self,
            ExerciseEntry.self,
            SetEntry.self,
            FoodEntry.self,
            BodyMeasurement.self,
            // COOK.
            Recipe.self,
            RecipeIngredient.self,
            PlannedMeal.self,
            ShoppingListCheck.self
        ]
    }
}

// MARK: - Plan

enum LiftMigrationPlan: SchemaMigrationPlan {

    static var schemas: [any VersionedSchema.Type] {
        [LiftSchemaV1.self, LiftSchemaV2.self]
    }

    static var stages: [MigrationStage] {
        [v1ToV2]
    }

    /// Four new model types and no change to any existing one, so SwiftData can
    /// do this itself. Existing rows are untouched.
    static let v1ToV2 = MigrationStage.lightweight(
        fromVersion: LiftSchemaV1.self,
        toVersion: LiftSchemaV2.self
    )
}
