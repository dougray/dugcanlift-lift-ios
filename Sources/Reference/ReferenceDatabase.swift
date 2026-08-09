import Foundation
import GRDB

// MARK: - Records

struct FoodRecord: Codable, FetchableRecord, Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var brand: String?
    var servingGrams: Double?
    var servingLabel: String?

    // Per 100 g. Scale before writing into a FoodEntry.
    var caloriesPer100g: Double
    var proteinPer100g: Double
    var carbsPer100g: Double
    var fatPer100g: Double
    var fiberPer100g: Double?
    var sugarPer100g: Double?
    var sodiumPer100g: Double?

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

    static let databaseTableName = "exercises"
}

// MARK: - Database

enum ReferenceDatabaseError: Error {
    case bundleResourceMissing(String)
}

/// Read-only access to the reference data shipped inside the app bundle.
///
/// Deliberately NOT SwiftData. This data is static, large, never edited by the
/// user, and needs full-text search — all things SQLite with an FTS5 index does
/// far better. Keeping it separate also means shipping an updated food database
/// is just replacing a file, with no schema migration of user data.
actor ReferenceDatabase {

    static let shared = ReferenceDatabase()

    private var queue: DatabaseQueue?

    private func connection() throws -> DatabaseQueue {
        if let queue { return queue }

        guard let url = Bundle.main.url(forResource: "reference", withExtension: "db") else {
            throw ReferenceDatabaseError.bundleResourceMissing("reference.db")
        }

        var configuration = Configuration()
        configuration.readonly = true
        // The bundle is code-signed and immutable, so no WAL and no writes.
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA query_only = ON")
        }

        let queue = try DatabaseQueue(path: url.path, configuration: configuration)
        self.queue = queue
        return queue
    }

    // MARK: Food search

    /// Prefix-matched full-text search. Ranking puts exact-ish matches first,
    /// which matters a lot when someone types "chick" mid-meal.
    func searchFoods(_ text: String, limit: Int = 30) async throws -> [FoodRecord] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return [] }

        return try await connection().read { db in
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

    /// Barcode lookup for Open Food Facts entries.
    func food(barcode: String) async throws -> FoodRecord? {
        try await connection().read { db in
            try FoodRecord.fetchOne(db, sql: "SELECT * FROM foods WHERE barcode = ? LIMIT 1",
                                    arguments: [barcode])
        }
    }

    func food(id: String) async throws -> FoodRecord? {
        try await connection().read { db in
            try FoodRecord.fetchOne(db, sql: "SELECT * FROM foods WHERE id = ?", arguments: [id])
        }
    }

    // MARK: Exercise search

    func searchExercises(_ text: String, limit: Int = 30) async throws -> [ExerciseRecord] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return try await allExercises(limit: limit) }

        return try await connection().read { db in
            guard let pattern = FTS5Pattern(matchingAllPrefixesIn: trimmed) else { return [] }
            return try ExerciseRecord.fetchAll(db, sql: """
                SELECT exercises.*
                FROM exercises
                JOIN exercises_fts ON exercises_fts.rowid = exercises.rowid
                WHERE exercises_fts MATCH ?
                ORDER BY bm25(exercises_fts)
                LIMIT ?
                """, arguments: [pattern, limit])
        }
    }

    func allExercises(limit: Int = 500) async throws -> [ExerciseRecord] {
        try await connection().read { db in
            try ExerciseRecord.fetchAll(db, sql: "SELECT * FROM exercises ORDER BY name LIMIT ?",
                                        arguments: [limit])
        }
    }

    func exercise(id: String) async throws -> ExerciseRecord? {
        try await connection().read { db in
            try ExerciseRecord.fetchOne(db, sql: "SELECT * FROM exercises WHERE id = ?",
                                        arguments: [id])
        }
    }
}
