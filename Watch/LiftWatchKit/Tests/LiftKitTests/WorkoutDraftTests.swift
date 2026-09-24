import XCTest
@testable import LiftKit
import LiftSync

/// The rules under test are stated in `docs/ARCHITECTURE.md`: a workout
/// snapshot is revisioned, and IDs stay stable so a phone can reconcile an
/// edit that was made while the watch was offline.
final class WorkoutDraftTests: XCTestCase {

    func testNewDraftStartsAtRevisionOne() {
        let draft = WorkoutDraft(name: "Quick Strength")
        XCTAssertEqual(draft.revision, 1)
    }

    func testEditingBumpsRevision() {
        var draft = WorkoutDraft(name: "Push")
        draft.addExercise(refID: "bench-barbell", name: "Bench Press")
        XCTAssertEqual(draft.revision, 2)

        draft.rename("Push A")
        XCTAssertEqual(draft.revision, 3)
    }

    func testEditingKeepsIdentifiersStable() throws {
        var draft = WorkoutDraft(name: "Push")
        let workoutID = draft.id
        let exerciseID = draft.addExercise(refID: "bench-barbell", name: "Bench Press")
        let setID = try XCTUnwrap(draft.appendSet(to: exerciseID, weightKg: 100, reps: 5))

        draft.rename("Push A")
        draft.completeSet(setID, at: Date(timeIntervalSince1970: 100))

        XCTAssertEqual(draft.id, workoutID)
        XCTAssertEqual(draft.exercises.first?.id, exerciseID)
        XCTAssertEqual(draft.exercises.first?.sets.first?.id, setID)
    }

    func testEditingAdvancesUpdatedAt() {
        var draft = WorkoutDraft(name: "Pull", now: Date(timeIntervalSince1970: 0))
        draft.rename("Pull A", now: Date(timeIntervalSince1970: 60))
        XCTAssertEqual(draft.updatedAt, Date(timeIntervalSince1970: 60))
    }

    func testWarmupSetsAreExcludedFromVolume() {
        var draft = WorkoutDraft(name: "Legs")
        let squat = draft.addExercise(refID: "squat-barbell", name: "Squat")
        draft.appendSet(to: squat, weightKg: 60, reps: 5, isWarmup: true)
        draft.appendSet(to: squat, weightKg: 100, reps: 5)

        XCTAssertEqual(draft.totalVolumeKg, 500, accuracy: 0.0001)
        XCTAssertEqual(draft.totalSetCount, 2)
    }

    func testSetDisplayMatchesPhoneFormatting() throws {
        var draft = WorkoutDraft(name: "Legs")
        let squat = draft.addExercise(refID: "squat-barbell", name: "Squat")
        let setID = try XCTUnwrap(draft.appendSet(to: squat, weightKg: 147.4176, reps: 5, rpe: 7.5))
        let set = try XCTUnwrap(draft.set(setID))

        XCTAssertEqual(set.display(unit: .pounds), "325 x 5 @7.5")
        XCTAssertEqual(set.display(unit: .kilograms), "147.4 x 5 @7.5")
    }

    // MARK: - Which limb a set was done on

    func testASetRecordsTheSideItWasDoneOn() throws {
        var draft = WorkoutDraft(name: "Lower A")
        let exercise = draft.addExercise(refID: "split-squat-dumbbell", name: "Split Squat")
        let left = try XCTUnwrap(draft.appendSet(to: exercise, weightKg: 13.6078, reps: 8,
                                                 side: .left))
        let both = try XCTUnwrap(draft.appendSet(to: exercise, weightKg: 60, reps: 8))

        XCTAssertEqual(draft.set(left)?.side, .left)
        // Absent is both, here as everywhere: nothing writes a "both".
        XCTAssertNil(draft.set(both)?.side)
        XCTAssertEqual(draft.set(left)?.display(unit: .pounds), "30 x 8 · L")
        XCTAssertEqual(draft.set(both)?.display(unit: .pounds), "132.3 x 8")
    }

    func testADraftWrittenBeforeSidesDecodesAsTwoSided() throws {
        // The watch stores its draft as JSON, so a session in progress when
        // this build installs must come back with its sets intact.
        let json = Data("""
        {"id":"6A2A8B6E-3D2F-4E77-9B4E-2C6A5E8C1D01","name":"Lower A",
         "focus":"bodybuilding","revision":3,
         "startedAt":0,"updatedAt":0,
         "exercises":[{"id":"6A2A8B6E-3D2F-4E77-9B4E-2C6A5E8C1D02",
           "exerciseRefID":"split-squat-dumbbell","name":"Split Squat","orderIndex":0,
           "sets":[{"id":"6A2A8B6E-3D2F-4E77-9B4E-2C6A5E8C1D03","orderIndex":0,
                    "weightKg":13.6078,"reps":8,"isWarmup":false}]}]}
        """.utf8)
        let draft = try JSONDecoder().decode(WorkoutDraft.self, from: json)
        let set = try XCTUnwrap(draft.exercises.first?.sets.first)
        XCTAssertNil(set.side)
        XCTAssertEqual(set.reps, 8)
    }

    func testASidedSetSurvivesTheDraftsOwnRoundTrip() throws {
        var draft = WorkoutDraft(name: "Lower A")
        let exercise = draft.addExercise(refID: "split-squat-dumbbell", name: "Split Squat")
        draft.appendSet(to: exercise, weightKg: 13.6078, reps: 8, side: .right)
        let data = try JSONEncoder().encode(draft)
        let decoded = try JSONDecoder().decode(WorkoutDraft.self, from: data)
        XCTAssertEqual(decoded.exercises.first?.sets.first?.side, .right)
        XCTAssertEqual(decoded, draft)
    }

    func testUnknownExerciseEditIsRejectedWithoutBumpingRevision() {
        var draft = WorkoutDraft(name: "Push")
        let before = draft.revision
        let result = draft.appendSet(to: UUID(), weightKg: 100, reps: 5)
        XCTAssertNil(result)
        XCTAssertEqual(draft.revision, before)
    }
}

final class WeightUnitTests: XCTestCase {
    func testKilogramRoundTrip() {
        let unit = WeightUnit.pounds
        XCTAssertEqual(unit.toKilograms(unit.fromKilograms(102.5)), 102.5, accuracy: 0.000001)
    }
}
