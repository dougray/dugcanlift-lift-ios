import XCTest
import SwiftData
@testable import Lift

final class PlanImporterTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: Schema(versionedSchema: LiftSchemaV3.self),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        return ModelContext(container)
    }

    private let examplePayload = PlanPayload(
        v: 1, t: "plan", l: "a1b2c3d4", n: "Coach Dana",
        r: [PlanRecipe(n: "Beef Chilli", s: 4, u: [438, 36, 31, 19, 9],
                       i: ["500 g lean beef mince"], t: ["Brown the mince."])],
        m: [PlanMeal(d: "2026-08-26", s: 2, x: 0, q: 2)],
        w: [PlanWorkout(n: "Lower A", e: [
            PlanWorkoutExercise(n: "Back Squat", q: "Barbell", c: "Belt on the last set.",
                                s: [[225, 5, 8], [225, 5, 8], [245, 3, 9]])
        ])],
        k: [PlanSession(d: "2026-09-08", x: 0)]
    )

    func testSummaryCountsEverything() {
        let summary = PlanImporter.summary(for: examplePayload)
        XCTAssertEqual(summary.coachName, "Coach Dana")
        XCTAssertEqual(summary.recipeCount, 1)
        XCTAssertEqual(summary.mealCount, 1)
        XCTAssertEqual(summary.workoutCount, 1)
        XCTAssertEqual(summary.scheduledSessionCount, 1)
    }

    func testAcceptCreatesARecipeMatchingWireUnits() throws {
        let context = try makeContext()
        try PlanImporter.accept(examplePayload, hash: "h1", in: context)

        let recipes = try context.fetch(FetchDescriptor<Recipe>())
        XCTAssertEqual(recipes.count, 1)
        XCTAssertEqual(recipes.first?.name, "Beef Chilli")
        XCTAssertEqual(recipes.first?.servings, 4)
        XCTAssertEqual(recipes.first?.nutritionPerServing?.calories, 438)
        XCTAssertEqual(recipes.first?.nutritionPerServing?.proteinG, 36)
        XCTAssertEqual(recipes.first?.ingredients?.first?.rawText, "500 g lean beef mince")
        XCTAssertEqual(recipes.first?.steps, ["Brown the mince."])
    }

    func testAcceptCreatesAPlannedMealReferencingTheImportedRecipe() throws {
        let context = try makeContext()
        try PlanImporter.accept(examplePayload, hash: "h2", in: context)

        let recipe = try XCTUnwrap(try context.fetch(FetchDescriptor<Recipe>()).first)
        let meals = try context.fetch(FetchDescriptor<PlannedMeal>())
        XCTAssertEqual(meals.count, 1)
        XCTAssertEqual(meals.first?.recipeID, recipe.id)
        XCTAssertEqual(meals.first?.mealType, .dinner) // slot 2
        XCTAssertEqual(meals.first?.servings, 2)
        XCTAssertEqual(meals.first?.dayKey, DayKey.make(from: try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-08-26T00:00:00Z")
        )))
    }

    func testAcceptCreatesARoutineWithWeightConvertedToKilograms() throws {
        let context = try makeContext()
        try PlanImporter.accept(examplePayload, hash: "h3", in: context)

        let routines = try context.fetch(FetchDescriptor<Routine>())
        XCTAssertEqual(routines.count, 1)
        XCTAssertEqual(routines.first?.name, "Lower A")

        let exercise = try XCTUnwrap(routines.first?.orderedExercises.first)
        XCTAssertEqual(exercise.name, "Back Squat")
        XCTAssertEqual(exercise.equipment, "Barbell")
        XCTAssertEqual(exercise.note, "Belt on the last set.")

        let sets = exercise.orderedSets
        XCTAssertEqual(sets.count, 3)
        XCTAssertEqual(sets[0].targetWeightKg ?? 0, WeightUnit.pounds.toKilograms(225), accuracy: 0.001)
        XCTAssertEqual(sets[0].targetReps, 5)
        XCTAssertEqual(sets[0].targetRPE, 8)
        XCTAssertEqual(sets[2].targetReps, 3)
        XCTAssertEqual(sets[2].targetRPE, 9)
    }

    func testAcceptSkipsAMealWithANegativeRecipeIndexInsteadOfCrashing() throws {
        // A malformed or adversarially-crafted plan link (untrusted input,
        // decoded externally) could carry a negative `x`. The guard in
        // accept() must reject it rather than subscript
        // createdRecipeIDs[planMeal.x] with a negative index, which would
        // trap (Swift arrays don't check the lower bound via `< count`
        // alone — `-1 < 1` is true).
        let context = try makeContext()
        let payloadWithNegativeIndex = PlanPayload(
            v: 1, t: "plan", l: "a1b2c3d4", n: "Coach Dana",
            r: examplePayload.r, m: [PlanMeal(d: "2026-08-26", s: 2, x: -1, q: 2)],
            w: examplePayload.w, k: examplePayload.k
        )

        try PlanImporter.accept(payloadWithNegativeIndex, hash: "negative-index", in: context)

        XCTAssertEqual(try context.fetch(FetchDescriptor<Recipe>()).count, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<PlannedMeal>()).count, 0)
    }

    func testAcceptAppliesScheduledSessionsAsScheduleReferences() throws {
        // k references w by array index. We assert only that accepting does
        // not throw and the routine it points to exists — the Train-tab
        // "Coach scheduled: X" surfacing is a view-layer concern (Task 6).
        let context = try makeContext()
        try PlanImporter.accept(examplePayload, hash: "h4", in: context)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Routine>()).count, 1)
    }

    func testAcceptingTheSameHashTwiceIsANoOp() throws {
        let context = try makeContext()
        try PlanImporter.accept(examplePayload, hash: "same-hash", in: context)
        try PlanImporter.accept(examplePayload, hash: "same-hash", in: context)

        XCTAssertEqual(try context.fetch(FetchDescriptor<Recipe>()).count, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Routine>()).count, 1)
    }

    func testIsAlreadyImportedReflectsAcceptedHashes() throws {
        let context = try makeContext()
        XCTAssertFalse(PlanImporter.isAlreadyImported("fresh", in: context))
        try PlanImporter.accept(examplePayload, hash: "fresh", in: context)
        XCTAssertTrue(PlanImporter.isAlreadyImported("fresh", in: context))
    }

    func testHashIsStableForIdenticalPayloadsAndDiffersForDifferentOnes() throws {
        let h1 = try PlanImporter.hash(of: examplePayload)
        let h2 = try PlanImporter.hash(of: examplePayload)
        XCTAssertEqual(h1, h2)

        var different = examplePayload
        different = PlanPayload(v: different.v, t: different.t, l: different.l,
                                 n: "Someone Else", r: different.r, m: different.m,
                                 w: different.w, k: different.k)
        XCTAssertNotEqual(h1, try PlanImporter.hash(of: different))
    }
}
