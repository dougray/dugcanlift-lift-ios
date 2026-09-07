import XCTest
import SwiftData
@testable import Lift

@MainActor
final class RoutineModelsTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: Schema(versionedSchema: LiftSchemaV3.self),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        return ModelContext(container)
    }

    func testStartSessionCreatesExercisesAndSetsFromTargets() throws {
        let context = try makeContext()
        let routine = Routine(name: "Lower A")
        let squat = RoutineExercise(name: "Back Squat", equipment: "Barbell", orderIndex: 0)
        squat.prescribedSets = [
            RoutinePrescribedSet(orderIndex: 0, targetWeightKg: 102.0585, targetReps: 5, targetRPE: 8),
            RoutinePrescribedSet(orderIndex: 1, targetReps: 5)
        ]
        routine.exercises = [squat]
        context.insert(routine)

        let date = Date(timeIntervalSince1970: 1_757_000_000)
        let day = routine.startSession(on: date, in: context)

        XCTAssertEqual(day.orderedExercises.count, 1)
        let entry = day.orderedExercises[0]
        XCTAssertEqual(entry.name, "Back Squat")
        XCTAssertEqual(entry.equipment, "Barbell")
        XCTAssertEqual(entry.orderedSets.count, 2)
        XCTAssertEqual(entry.orderedSets[0].weightKg, 102.0585, accuracy: 0.001)
        XCTAssertEqual(entry.orderedSets[0].reps, 5)
        XCTAssertEqual(entry.orderedSets[0].rpe, 8)
        XCTAssertEqual(entry.orderedSets[1].weightKg, 0)
        XCTAssertEqual(entry.orderedSets[1].reps, 5)
    }

    func testStartSessionSkipsDurationOnlyPrescribedSets() throws {
        // Documented gap: iOS's SetEntry has no duration/distance fields yet.
        // A conditioning-only prescription must not silently become a
        // zero-weight, zero-rep strength set — it is skipped entirely.
        let context = try makeContext()
        let routine = Routine(name: "Conditioning")
        let piece = RoutineExercise(name: "Row", orderIndex: 0)
        piece.prescribedSets = [
            RoutinePrescribedSet(orderIndex: 0, targetDurationSec: 600, targetDistanceMeters: 1600)
        ]
        routine.exercises = [piece]
        context.insert(routine)

        let day = routine.startSession(on: .now, in: context)
        XCTAssertEqual(day.orderedExercises.first?.orderedSets.count, 0)
    }

    func testStartSessionReusesExistingDayForTheSameDate() throws {
        let context = try makeContext()
        let date = Date(timeIntervalSince1970: 1_757_000_000)
        _ = WorkoutQueries.fetchOrCreate(date, in: context)

        let routine = Routine(name: "Push")
        routine.exercises = [RoutineExercise(name: "Bench Press", orderIndex: 0)]
        context.insert(routine)

        let day = routine.startSession(on: date, in: context)
        XCTAssertEqual(try context.fetch(FetchDescriptor<WorkoutDay>()).count, 1)
        XCTAssertEqual(day.orderedExercises.count, 1)
    }
}
