import Foundation
import GRDB

// MARK: - Records

struct FoodRecord: Codable, FetchableRecord, Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var brand: String?
    var servingGrams: Double?
    var servingLabel: String?

    var caloriesPer100g: Double
    var proteinPer100g: Double
    var carbsPer100g: Double
    var fatPer100g: Double
    var fiberPer100g: Double?
    var sugarPer100g: Double?
    var sodiumPer100g: Double?
    var source: String

    static let databaseTableName = "foods"

    /// Convert a chosen portion into the immutable snapshot stored on FoodEntry.
    func nutrition(grams: Double) -> NutritionFacts {
        let factor = grams / 100.0
        return NutritionFacts(
            calories: caloriesPer100g * factor,
            proteinG: proteinPer100g * factor,
            carbsG:   carbsPer100g * factor,
            fatG:     fatPer100g * factor,
            fiberG:   fiberPer100g.map { $0 * factor },
            sugarG:   sugarPer100g.map { $0 * factor },
            sodiumMg: sodiumPer100g.map { $0 * factor }
        )
    }
}

struct ExerciseRecord: Codable, FetchableRecord, Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var primaryMuscle: String?
    var equipment: String?
    var instructions: String?
    var source: String

    static let databaseTableName = "exercises"
}

enum ReferenceDatabaseError: Error {
    case bundleResourceMissing(String)
}

/// Read-only access to the reference data shipped inside the app bundle.
///
/// TWO separate databases, deliberately never joined:
///
///   food.db       USDA (public domain) + Open Food Facts (ODbL)
///   exercises.db  free-exercise-db (public domain) + wger (CC-BY-SA 3.0)
///
/// ODbL and CC-BY-SA 3.0 are both share-alike and mutually incompatible.
/// Keeping them in separate files makes this a Collective Database rather than
/// a Derivative one, so each obligation stays scoped to its own file.
/// Never write a query spanning both.
///
/// Deliberately NOT SwiftData: this data is static, large, never user-edited,
/// and needs full-text search. Shipping an update is a file replacement with
/// no migration of user data.
actor ReferenceDatabase {

    static let shared = ReferenceDatabase()

    private var foodQueue: DatabaseQueue?
    private var exerciseQueue: DatabaseQueue?

    private func open(_ resource: String) throws -> DatabaseQueue {
        guard let url = Bundle.main.url(forResource: resource, withExtension: "db") else {
            throw ReferenceDatabaseError.bundleResourceMissing("\(resource).db")
        }
        var configuration = Configuration()
        configuration.readonly = true
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA query_only = ON")
        }
        return try DatabaseQueue(path: url.path, configuration: configuration)
    }

    private func foods() throws -> DatabaseQueue {
        if let foodQueue { return foodQueue }
        let queue = try open("food")
        foodQueue = queue
        return queue
    }

    private func exercises() throws -> DatabaseQueue {
        if let exerciseQueue { return exerciseQueue }
        let queue = try open("exercises")
        exerciseQueue = queue
        return queue
    }

    // MARK: Food

    /// Prefix-matched full-text search, ranked by bm25 then name length so
    /// short exact-ish matches win. Matters when someone types "chick"
    /// mid-meal and wants plain chicken breast, not "Chickpea Snack Bar".
    func searchFoods(_ text: String, limit: Int = 30) throws -> [FoodRecord] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return [] }

        return try foods().read { db in
            guard let pattern = FTS5Pattern(matchingAllPrefixesIn: trimmed) else { return [] }
            return try FoodRecord.fetchAll(db, sql: """
                SELECT foods.*
                FROM foods
                JOIN foods_fts ON foods_fts.rowid = foods.rowid
                WHERE foods_fts MATCH ?
                ORDER BY bm25(foods_fts), length(foods.name)
                LIMIT ?
                """, arguments: [pattern, limit])
        }
    }

    func food(barcode: String) throws -> FoodRecord? {
        try foods().read { db in
            try FoodRecord.fetchOne(db,
                sql: "SELECT * FROM foods WHERE barcode = ? LIMIT 1", arguments: [barcode])
        }
    }

    func food(id: String) throws -> FoodRecord? {
        try foods().read { db in
            try FoodRecord.fetchOne(db, sql: "SELECT * FROM foods WHERE id = ?", arguments: [id])
        }
    }

    // MARK: Exercises

    func searchExercises(_ text: String, limit: Int = 30) throws -> [ExerciseRecord] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return try allExercises(limit: limit) }

        return try exercises().read { db in
            guard let pattern = FTS5Pattern(matchingAllPrefixesIn: trimmed) else { return [] }
            // bm25 alone ranks "Barbell Rollout from Bench" alongside
            // "Bench Press" for the query "bench". Three-tier ordering:
            // names that START with the query win, then relevance with the
            // name column weighted 10x over muscle, then shorter names —
            // which favours the canonical lift over its variations.
            return try ExerciseRecord.fetchAll(db, sql: """
                SELECT exercises.*
                FROM exercises
                JOIN exercises_fts ON exercises_fts.rowid = exercises.rowid
                WHERE exercises_fts MATCH ?
                ORDER BY
                    CASE WHEN exercises.name LIKE ? THEN 0 ELSE 1 END,
                    bm25(exercises_fts, 10.0, 1.0),
                    length(exercises.name)
                LIMIT ?
                """, arguments: [pattern, "\(trimmed)%", limit])
        }
    }

    func allExercises(limit: Int = 1000) throws -> [ExerciseRecord] {
        try exercises().read { db in
            try ExerciseRecord.fetchAll(db,
                sql: "SELECT * FROM exercises ORDER BY name LIMIT ?", arguments: [limit])
        }
    }

    func exercise(id: String) throws -> ExerciseRecord? {
        try exercises().read { db in
            try ExerciseRecord.fetchOne(db,
                sql: "SELECT * FROM exercises WHERE id = ?", arguments: [id])
        }
    }
}
