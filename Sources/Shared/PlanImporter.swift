import Foundation
import CryptoKit
import SwiftData

/// Tracks which plan links have already been accepted, by a hash of their
/// decoded content — not by any id from the wire format, because
/// PLAN-FORMAT.md gives recipes and workouts no stable id at all (they are
/// referenced by array position within one payload). This is link-level
/// idempotency ("did I already import this exact link") not content-level
/// deduplication ("is this the same recipe as one I already have") — a
/// revised resend of "Lower A" is a second, separate routine. See the design
/// spec's "Landing the data" section for why.
@Model
final class ImportedPlan {
    var id: UUID = UUID()
    var payloadHash: String = ""
    var importedAt: Date = Date.now

    init(payloadHash: String, importedAt: Date = .now) {
        self.id = UUID()
        self.payloadHash = payloadHash
        self.importedAt = importedAt
    }
}

struct PlanImportSummary: Equatable {
    var coachName: String
    var recipeCount: Int
    var mealCount: Int
    var workoutCount: Int
    var scheduledSessionCount: Int
}

enum PlanImporter {

    static func summary(for payload: PlanPayload) -> PlanImportSummary {
        PlanImportSummary(
            coachName: payload.n,
            recipeCount: payload.r?.count ?? 0,
            mealCount: payload.m?.count ?? 0,
            workoutCount: payload.w?.count ?? 0,
            scheduledSessionCount: payload.k?.count ?? 0
        )
    }

    /// SHA-256 over the exact JSON the payload decoded from is not available
    /// here (only the parsed struct is), so this hashes a canonical
    /// re-encoding instead. `PlanPayload` and its children are all
    /// `Encodable`-free by design (decode-only) — add `Encodable` conformance
    /// via this local mirror rather than widening the wire-format structs'
    /// purpose.
    static func hash(of payload: PlanPayload) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(HashableMirror(of: payload))
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func isAlreadyImported(_ hash: String, in context: ModelContext) -> Bool {
        let descriptor = FetchDescriptor<ImportedPlan>(
            predicate: #Predicate { $0.payloadHash == hash }
        )
        return (try? context.fetch(descriptor).isEmpty) == false
    }

    static func accept(_ payload: PlanPayload, hash: String, in context: ModelContext) throws {
        guard !isAlreadyImported(hash, in: context) else { return }

        var createdRecipeIDs: [UUID] = []

        for planRecipe in payload.r ?? [] {
            let recipe = Recipe(
                name: planRecipe.n,
                servings: planRecipe.s,
                steps: planRecipe.t ?? []
            )
            if let u = planRecipe.u, u.count >= 4 {
                recipe.nutritionPerServing = NutritionFacts(
                    calories: u[0], proteinG: u[1], carbsG: u[2], fatG: u[3],
                    fiberG: u.count > 4 ? u[4] : nil
                )
            }
            recipe.ingredients = (planRecipe.i ?? []).enumerated().map { index, rawText in
                RecipeIngredient(rawText: rawText, sortOrder: index)
            }
            context.insert(recipe)
            createdRecipeIDs.append(recipe.id)
        }

        let dateFormatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.dateFormat = "yyyy-MM-dd"
            return formatter
        }()

        for planMeal in payload.m ?? [] {
            guard planMeal.x >= 0, planMeal.x < createdRecipeIDs.count,
                  let mealType = mealType(forSlot: planMeal.s),
                  let date = dateFormatter.date(from: planMeal.d) else { continue }
            // Bind to a local constant before the #Predicate closure rather
            // than subscripting inside it — matches the pattern
            // WorkoutQueries.day(_:) already uses elsewhere in this codebase.
            let targetRecipeID = createdRecipeIDs[planMeal.x]
            let recipeDescriptor = FetchDescriptor<Recipe>(
                predicate: #Predicate { $0.id == targetRecipeID }
            )
            guard let recipe = try context.fetch(recipeDescriptor).first else { continue }
            context.insert(PlannedMeal(
                recipe: recipe, mealType: mealType, plannedFor: date, servings: planMeal.q
            ))
        }

        var createdRoutineIDs: [UUID] = []

        for planWorkout in payload.w ?? [] {
            let routine = Routine(name: planWorkout.n)
            routine.exercises = planWorkout.e.enumerated().map { exerciseIndex, planExercise in
                let exercise = RoutineExercise(
                    name: planExercise.n,
                    equipment: planExercise.q ?? "",
                    orderIndex: exerciseIndex,
                    note: planExercise.c
                )
                exercise.prescribedSets = planExercise.s.enumerated().map { setIndex, tuple in
                    RoutinePrescribedSet(
                        orderIndex: setIndex,
                        targetWeightKg: value(tuple, 0).map { WeightUnit.pounds.toKilograms($0) },
                        targetReps: value(tuple, 1).map { Int($0) },
                        targetRPE: value(tuple, 2),
                        targetDurationSec: value(tuple, 3).map { Int($0) },
                        targetDistanceMeters: value(tuple, 4)
                    )
                }
                return exercise
            }
            context.insert(routine)
            createdRoutineIDs.append(routine.id)
        }

        // Scheduled sessions (`k`) are intentionally not turned into anything
        // here — per the design spec, a schedule is a lightweight reference
        // surfaced on the relevant day in the Train tab (Task 6), not a
        // pre-created WorkoutDay. `createdRoutineIDs` is threaded through so
        // that view has a routine id to point at.
        _ = payload.k // referenced by Task 6's schedule surfacing
        _ = createdRoutineIDs

        context.insert(ImportedPlan(payloadHash: hash))
        try context.save()
    }

    private static func value(_ tuple: [Double?], _ index: Int) -> Double? {
        guard index < tuple.count else { return nil }
        return tuple[index]
    }

    private static func mealType(forSlot slot: Int) -> MealType? {
        switch slot {
        case 0: return .breakfast
        case 1: return .lunch
        case 2: return .dinner
        case 3: return .snack
        default: return nil
        }
    }
}

/// A private, `Encodable` mirror of `PlanPayload` used only to produce a
/// stable hash. Kept separate from the wire-format structs in
/// `PlanLinkCodec.swift` so those stay decode-only, matching their one job.
private struct HashableMirror: Encodable {
    let v: Int
    let t: String
    let l: String
    let n: String
    let r: [PlanRecipe]?
    let m: [PlanMeal]?
    let w: [PlanWorkout]?
    let k: [PlanSession]?

    init(of payload: PlanPayload) {
        v = payload.v; t = payload.t; l = payload.l; n = payload.n
        r = payload.r; m = payload.m; w = payload.w; k = payload.k
    }
}

extension PlanRecipe: Encodable {
    enum CodingKeys: String, CodingKey { case n, s, u, i, t }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(n, forKey: .n); try c.encode(s, forKey: .s)
        try c.encodeIfPresent(u, forKey: .u); try c.encodeIfPresent(i, forKey: .i)
        try c.encodeIfPresent(t, forKey: .t)
    }
}
extension PlanMeal: Encodable {
    enum CodingKeys: String, CodingKey { case d, s, x, q }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(d, forKey: .d); try c.encode(s, forKey: .s)
        try c.encode(x, forKey: .x); try c.encode(q, forKey: .q)
    }
}
extension PlanWorkout: Encodable {
    enum CodingKeys: String, CodingKey { case n, e }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(n, forKey: .n); try c.encode(e, forKey: .e)
    }
}
extension PlanWorkoutExercise: Encodable {
    enum CodingKeys: String, CodingKey { case n, q, c, s }
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(n, forKey: .n)
        try container.encodeIfPresent(q, forKey: .q)
        try container.encodeIfPresent(c, forKey: .c)
        try container.encode(s, forKey: .s)
    }
}
extension PlanSession: Encodable {
    enum CodingKeys: String, CodingKey { case d, x }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(d, forKey: .d); try c.encode(x, forKey: .x)
    }
}
