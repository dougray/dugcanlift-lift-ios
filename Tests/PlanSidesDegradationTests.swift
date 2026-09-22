import XCTest
import SwiftData
import LiftCore
@testable import Lift

/// Old-decoder degradation: how a LIFT iOS build that has never heard of plan
/// sides reads a plan that carries them.
///
/// `Fixtures/web-plan-per-side.txt` is a plan link Coach web's own encoder
/// wrote (dugcanlift-coach, `coach/fixtures/`, the same bytes): `b: 1` on two
/// exercises and six-field set tuples whose sixth position names a side.
/// PLAN-FORMAT.md "Sides" promises that a decoder without either ignores both
/// and shows ordinary two-sided sets with the right weights, reps and count.
/// Never regenerate the fixture from Swift; its value is that a different
/// implementation wrote it.
///
/// This runs the fixture through `PlanLinkCodec.decode` (LiftKit 1.9.0),
/// `PlanImporter.accept` and `Routine.startSession` exactly as they stand on
/// main before plan sides, and asserts what a lifter would get.
final class PlanSidesDegradationTests: XCTestCase {

    static func fixtureFragment() throws -> String {
        let url = try XCTUnwrap(Bundle(for: PlanSidesDegradationTests.self)
            .url(forResource: "web-plan-per-side", withExtension: "txt"),
            "web-plan-per-side.txt missing from the test bundle")
        let link = try String(contentsOf: url, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let hash = try XCTUnwrap(link.firstIndex(of: "#"))
        return String(link[link.index(after: hash)...])
    }

    @MainActor
    func testOldDecoderReadsThePerSideFixtureAsTwoSidedSets() throws {
        let payload = try PlanLinkCodec.decode(fragment: Self.fixtureFragment(),
                                               expectedLifterID: "a1b2c3d4")
        XCTAssertEqual(payload.v, 1, "no version bump, so an old build does not refuse the link")

        let context = ModelContext(LiftStore.makeContainer(inMemory: true))
        try PlanImporter.accept(payload, hash: PlanImporter.hash(of: payload), in: context)

        let routine = try XCTUnwrap(try context.fetch(FetchDescriptor<Routine>()).first)
        XCTAssertEqual(routine.name, "Per-side A")
        let exercises = routine.orderedExercises
        XCTAssertEqual(exercises.map(\.name), [
            "Back Squat", "Single-Arm Dumbbell Row", "Bulgarian Split Squat",
            "Dumbbell Bench Press", "Suitcase Carry",
        ])
        XCTAssertEqual(exercises.map { $0.orderedSets.count }, [3, 3, 4, 3, 1])

        // Pounds on the wire, kilograms in the store: the conversion must
        // survive a six-field tuple exactly as it does a five-field one.
        func kg(_ lb: Double) -> Double { WeightUnit.pounds.toKilograms(lb) }
        func weightsAndReps(_ exercise: RoutineExercise) -> [[Double?]] {
            exercise.orderedSets.map { [$0.targetWeightKg, $0.targetReps.map(Double.init), $0.targetRPE] }
        }
        XCTAssertEqual(weightsAndReps(exercises[0]), Array(repeating: [kg(225), 5, 8], count: 3))
        XCTAssertEqual(weightsAndReps(exercises[1]), Array(repeating: [kg(30), 8, nil], count: 3))
        XCTAssertEqual(weightsAndReps(exercises[2]), Array(repeating: [kg(40), 8, nil], count: 4))
        XCTAssertEqual(weightsAndReps(exercises[3]), [[kg(60), 8, nil], [kg(60), 8, nil], [kg(40), 10, nil]])
        let carry = try XCTUnwrap(exercises[4].orderedSets.first)
        XCTAssertNil(carry.targetWeightKg)
        XCTAssertNil(carry.targetReps)
        XCTAssertEqual(carry.targetDurationSec, 600)
        XCTAssertEqual(carry.targetDistanceMeters, 1600, "distance stays in its own slot")
        XCTAssertEqual(exercises[2].note, "Extra set on the left.")

        // Started, every set lands as an ordinary two-sided set.
        let day = routine.startSession(on: .now, in: context)
        let logged = day.orderedExercises
        XCTAssertEqual(logged.map { $0.sets.count }, [3, 3, 4, 3, 1])
        XCTAssertEqual(logged[3].orderedSets.map(\.reps), [8, 8, 10])
        XCTAssertEqual(logged[3].orderedSets.map(\.weightKg), [kg(60), kg(60), kg(40)])
        for set in logged.flatMap(\.sets) {
            XCTAssertNil(set.side, "nothing about a side leaks through")
        }
    }
}
