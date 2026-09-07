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

/// A coach's scheduled session (`k` in PLAN-FORMAT.md) — a date paired with a
/// routine, surfaced on that day in the Train tab. Does NOT pre-create a
/// WorkoutDay; starting it is the same manual action as starting any routine.
@Model
final class ScheduledSession {
    var id: UUID = UUID()
    var routineID: UUID = UUID()
    var routineName: String = ""
    var dayKey: String = ""
    var scheduledFor: Date = Date.now

    init(routineID: UUID, routineName: String, scheduledFor: Date) {
        self.id = UUID()
        self.routineID = routineID
        self.routineName = routineName
        self.dayKey = DayKey.make(from: scheduledFor)
        self.scheduledFor = scheduledFor
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

        // Parse in the local calendar, not UTC: "yyyy-MM-dd" is a calendar
        // date with no time component (PLAN-FORMAT.md), so it must be
        // interpreted in the device's own timezone or it silently shifts by a
        // day for anyone west of UTC. Landing at midday rather than midnight
        // avoids a second hazard: DayKey.make (local-time by default) would
        // otherwise re-key a midnight local date back across the day
        // boundary depending on DST — see CookView.swift's `add(_:...)` for
        // the same convention.
        let dateFormatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .current
            formatter.dateFormat = "yyyy-MM-dd"
            return formatter
        }()

        func atMidday(_ date: Date) -> Date {
            Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: date) ?? date
        }

        for planMeal in payload.m ?? [] {
            guard planMeal.x >= 0, planMeal.x < createdRecipeIDs.count,
                  let mealType = mealType(forSlot: planMeal.s),
                  let parsedDate = dateFormatter.date(from: planMeal.d) else { continue }
            let date = atMidday(parsedDate)
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

        for session in payload.k ?? [] {
            guard session.x >= 0, session.x < createdRoutineIDs.count,
                  let parsedDate = dateFormatter.date(from: session.d) else { continue }
            let date = atMidday(parsedDate)
            let routineID = createdRoutineIDs[session.x] // already a local constant, safe to use directly
            let routineDescriptor = FetchDescriptor<Routine>(
                predicate: #Predicate { $0.id == routineID }
            )
            guard let routine = try context.fetch(routineDescriptor).first else { continue }
            context.insert(ScheduledSession(
                routineID: routineID, routineName: routine.name, scheduledFor: date
            ))
        }

        context.insert(ImportedPlan(payloadHash: hash))
        do {
            try context.save()
        } catch {
            // Roll back every pending insert above (recipes, meals, routines,
            // sessions, the ImportedPlan marker) so a retry after a failed
            // save starts clean. Without this, isAlreadyImported(hash:in:)
            // would see the still-pending (uncommitted but
            // fetch-visible-in-this-context) ImportedPlan insert from this
            // failed attempt and report "already imported" on the very next
            // call, even though nothing was actually persisted.
            context.rollback()
            throw error
        }
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
