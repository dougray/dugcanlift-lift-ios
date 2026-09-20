import XCTest
import SwiftData
import LiftCore
@testable import Lift

@MainActor
final class RoutineModelsTests: XCTestCase {

    /// `LiftStore.schema`, never a version pinned by hand. This named
    /// `LiftSchemaV7` while V7 was current; when V8 pointed V7 at
    /// `LiftPreSideShapes`, `startSession` went on inserting the live
    /// `WorkoutDay` into a container that no longer held that class and every
    /// test here died on a cast inside SwiftData.
    private func makeContext() throws -> ModelContext {
        ModelContext(LiftStore.makeContainer(inMemory: true))
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

    func testStartSessionCarriesTimedAndDistanceSets() throws {
        // SetEntry has held time and distance since schema V6. A mobility or
        // running routine used to start with no sets at all, because the
        // filter only counted weight and reps.
        let context = try makeContext()
        let routine = Routine(name: "Conditioning")
        let piece = RoutineExercise(name: "Row", orderIndex: 0)
        piece.prescribedSets = [
            RoutinePrescribedSet(orderIndex: 0, targetDurationSec: 600, targetDistanceMeters: 1600),
            RoutinePrescribedSet(orderIndex: 1, targetDurationSec: 45),
            RoutinePrescribedSet(orderIndex: 2)
        ]
        routine.exercises = [piece]
        context.insert(routine)

        let day = routine.startSession(on: .now, in: context)
        let sets = try XCTUnwrap(day.orderedExercises.first).orderedSets
        XCTAssertEqual(sets.count, 2, "a set prescribing nothing is still skipped")
        XCTAssertEqual(sets[0].durationSec, 600)
        XCTAssertEqual(sets[0].distanceMeters, 1600)
        XCTAssertEqual(sets[1].durationSec, 45)
        XCTAssertNil(sets[1].distanceMeters)
    }

    func testStartSessionNamesABlankDayButKeepsAnExistingName() throws {
        let context = try makeContext()
        let date = Date(timeIntervalSince1970: 1_757_000_000)
        let mobility = Routine(name: "Mobility")
        mobility.exercises = [RoutineExercise(name: "Cat Stretch", orderIndex: 0)]
        context.insert(mobility)
        XCTAssertEqual(mobility.startSession(on: date, in: context).name, "Mobility")

        let other = Date(timeIntervalSince1970: 1_757_200_000)
        let named = WorkoutQueries.fetchOrCreate(other, in: context)
        named.name = "Saturday"
        XCTAssertEqual(mobility.startSession(on: other, in: context).name, "Saturday")
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
