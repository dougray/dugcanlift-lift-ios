import XCTest
import SwiftData
import LiftCore
import LiftReference
@testable import Lift

/// Run against the **shipped** `splits.json` and the **shipped** exercise
/// database, because the thing most worth proving about a starter split is
/// that it agrees with the library. A test over a hand-written sample would
/// pass on a file the app doesn't have.
final class StarterSplitsTests: XCTestCase {

    private var splits: [StarterSplit] {
        StarterSplits.bundled(in: Bundle(for: type(of: self)))
    }

    // MARK: - The names are the library's names

    func testEveryExerciseExistsInTheLibrary() async throws {
        // This is the reason splits waited on the library. A name that does
        // not match what the app searches generates history that lines up
        // with nothing: no previous-set lookup, no trend line, no coach
        // agreement.
        let all = try await ReferenceDatabase.shared.allExercises(limit: 2000)
        let known = Set(all.map(\.name))

        let strangers = splits.flatMap { split in
            split.exercises.filter { !known.contains($0.name) }.map { "\(split.name): \($0.name)" }
        }
        XCTAssertTrue(strangers.isEmpty, "not in exercises.db — \(strangers)")
    }

    func testEveryEquipmentStringIsTheLibrarySpellingTitleCased() async throws {
        // The browser and Android store "Barbell"; the database holds
        // "barbell". These files are written in the stored spelling so that a
        // set logged from a split and the same lift picked from the picker
        // are the same lift.
        let all = try await ReferenceDatabase.shared.allExercises(limit: 2000)
        let equipmentByName = Dictionary(all.map { ($0.name, $0.equipment ?? "") },
                                         uniquingKeysWith: { first, _ in first })

        let wrong = splits.flatMap { split in
            split.exercises.compactMap { exercise -> String? in
                guard let raw = equipmentByName[exercise.name] else { return nil }
                let expected = raw.split(separator: " ")
                    .map { $0.prefix(1).uppercased() + $0.dropFirst() }
                    .joined(separator: " ")
                return exercise.equipment == expected
                    ? nil
                    : "\(exercise.name): '\(exercise.equipment)' should be '\(expected)'"
            }
        }
        XCTAssertTrue(wrong.isEmpty, "\(wrong)")
    }

    // MARK: - What shipped

    func testTheSixSplitsAreThereInThreeFolders() {
        XCTAssertEqual(splits.count, 6)
        XCTAssertEqual(splits.map(\.name),
                       ["Push", "Pull", "Legs", "Upper", "Lower", "Full Body"])
        XCTAssertEqual(Array(NSOrderedSet(array: splits.map(\.folder))) as? [String],
                       ["Push/Pull/Legs", "Upper/Lower", "Full Body"])
    }

    func testEverySplitHoldsRealWork() {
        for split in splits {
            XCTAssertFalse(split.exercises.isEmpty, "\(split.name) has no exercises")
            for exercise in split.exercises {
                XCTAssertGreaterThan(exercise.sets, 0, "\(split.name)/\(exercise.name)")
                XCTAssertTrue(exercise.reps != nil || exercise.durationSec != nil,
                              "\(split.name)/\(exercise.name) prescribes neither reps nor time")
            }
        }
    }

    func testPushPullLegsDoesNotDeadliftTwiceInARotation() {
        // Doug's call on 2026-09-14: a Barbell Deadlift on Pull and a Romanian
        // Deadlift on Legs in the same week is too much posterior chain for
        // whoever is most likely to tap a canned split. If a later edit puts a
        // second one back, that should be a decision rather than an accident.
        let ppl = splits.filter { $0.folder == "Push/Pull/Legs" }
        let deadlifts = ppl.flatMap { $0.exercises.filter { $0.name.lowercased().contains("deadlift") } }
        XCTAssertEqual(deadlifts.count, 1, "deadlifts across PPL: \(deadlifts.map(\.name))")
    }

    func testTheTimedExerciseIsTimedAndNotRepped() throws {
        let fullBody = try XCTUnwrap(splits.first { $0.name == "Full Body" })
        let plank = try XCTUnwrap(fullBody.exercises.last)
        XCTAssertEqual(plank.name, "Plank")
        XCTAssertEqual(plank.durationSec, 45)
        XCTAssertNil(plank.reps, "a plank has no rep count")
    }

    // MARK: - Adding one

    @MainActor
    func testAddingOneCreatesOnePrescribedSetPerSet() throws {
        // Android keeps a set *count*; this app models each set as its own
        // object. Four sets of six has to become four objects, not one.
        let container = try ModelContainer(
            for: Routine.self, RoutineExercise.self, RoutinePrescribedSet.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = container.mainContext

        let legs = try XCTUnwrap(splits.first { $0.name == "Legs" })
        let routine = StarterSplits.insert(legs, into: context)

        XCTAssertEqual(routine.name, "Legs")
        XCTAssertEqual(routine.folder, "Push/Pull/Legs")
        XCTAssertEqual(routine.orderedExercises.count, legs.exercises.count)

        let squat = try XCTUnwrap(routine.orderedExercises.first)
        XCTAssertEqual(squat.name, "Barbell Squat")
        XCTAssertEqual(squat.equipment, "Barbell")
        XCTAssertEqual(squat.orderedSets.count, 4, "four sets means four objects")
        XCTAssertEqual(squat.orderedSets.map(\.targetReps), [6, 6, 6, 6])
        XCTAssertNil(squat.orderedSets.first?.targetWeightKg,
                     "a starter prescribes the work, not the load")
    }

    @MainActor
    func testTheOrderOfExercisesSurvives() throws {
        let container = try ModelContainer(
            for: Routine.self, RoutineExercise.self, RoutinePrescribedSet.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let push = try XCTUnwrap(splits.first { $0.name == "Push" })
        let routine = StarterSplits.insert(push, into: container.mainContext)

        XCTAssertEqual(routine.orderedExercises.map(\.name), push.exercises.map(\.name),
                       "a split is an order, not a set — the big lift comes first")
    }

    @MainActor
    func testATimedExerciseArrivesWithTimeAndNoReps() throws {
        let container = try ModelContainer(
            for: Routine.self, RoutineExercise.self, RoutinePrescribedSet.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let full = try XCTUnwrap(splits.first { $0.name == "Full Body" })
        let routine = StarterSplits.insert(full, into: container.mainContext)

        let plank = try XCTUnwrap(routine.orderedExercises.last)
        XCTAssertEqual(plank.name, "Plank")
        XCTAssertEqual(plank.orderedSets.map(\.targetDurationSec), [45, 45, 45])
        XCTAssertNil(plank.orderedSets.first?.targetReps)
    }

    // MARK: - Recognising one already added

    @MainActor
    func testAStarterAlreadyAddedIsRecognisedByFolderAndName() throws {
        let container = try ModelContainer(
            for: Routine.self, RoutineExercise.self, RoutinePrescribedSet.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = container.mainContext
        let push = try XCTUnwrap(splits.first { $0.name == "Push" })

        XCTAssertFalse(StarterSplits.isAlreadySaved(push, in: []))
        StarterSplits.insert(push, into: context)
        let saved = try context.fetch(FetchDescriptor<Routine>())
        XCTAssertTrue(StarterSplits.isAlreadySaved(push, in: saved))
    }

    @MainActor
    func testARenamedCopyGetsTheStarterOfferedAgain() throws {
        // The alternative is a starter that disappears because of an edit made
        // to something else, which is worse than an occasional duplicate.
        let push = try XCTUnwrap(splits.first { $0.name == "Push" })
        let renamed = Routine(name: "Monday", folder: "Push/Pull/Legs")
        XCTAssertFalse(StarterSplits.isAlreadySaved(push, in: [renamed]))
    }

    @MainActor
    func testTheSameNameInAnotherFolderIsADifferentRoutine() throws {
        let lower = try XCTUnwrap(splits.first { $0.name == "Lower" })
        XCTAssertFalse(StarterSplits.isAlreadySaved(lower, in: [Routine(name: "Lower", folder: "Mine")]))
    }

    // MARK: - Malformed input

    func testOneBadEntryCostsThatSplitNotTheList() throws {
        let json = """
        {"routines":[
          {"folder":"F","name":"Good","exercises":[{"name":"Squat","sets":3,"reps":5}]},
          {"folder":"F","name":"","exercises":[{"name":"Squat","sets":3,"reps":5}]},
          {"folder":"F","name":"Empty","exercises":[]},
          {"folder":"F","name":"Nameless","exercises":[{"name":"","sets":3}]}
        ]}
        """
        let parsed = StarterSplits.decode(Data(json.utf8))
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed.first?.name, "Good")
    }

    func testAMissingSetsCountFallsBackRatherThanShippingZeroSets() {
        let parsed = StarterSplits.decode(Data("""
        {"routines":[{"name":"X","exercises":[{"name":"Squat"}]}]}
        """.utf8))
        XCTAssertEqual(parsed.first?.exercises.first?.sets, 3)
        XCTAssertNil(parsed.first?.exercises.first?.reps)
    }

    func testRubbishIsEmptyNotACrash() {
        XCTAssertTrue(StarterSplits.decode(Data("not json".utf8)).isEmpty)
        XCTAssertTrue(StarterSplits.decode(Data(#"{"v":1}"#.utf8)).isEmpty)
    }
}
