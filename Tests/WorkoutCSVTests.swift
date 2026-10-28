import XCTest
import SwiftData
import LiftCore
@testable import Lift

/// The fixtures are built from the shapes of real exports people have
/// published (none of the three apps documents its format), not copied from a
/// maker. See `WorkoutCSV`.
final class WorkoutCSVTests: XCTestCase {

    private func fixture(_ name: String) throws -> String {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "csv"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func day(_ date: Date) -> String { DayKey.make(from: date) }

    // MARK: - Reading

    func testStrongsSemicolonExportIsKilogramsAndSkipsItsPseudoRows() throws {
        let reading = try WorkoutCSV.read(fixture("csv-strong-semicolon"))
        XCTAssertEqual(reading.source, .strong)
        XCTAssertFalse(reading.needsUnit)
        let workouts = reading.parse(nil)
        XCTAssertEqual(workouts.map(\.name), ["Upper A", "Lower A"])
        let bench = try XCTUnwrap(workouts[0].exercises.first)
        XCTAssertEqual(bench.name, "Bench Press")
        XCTAssertEqual(bench.equipment, "Barbell")
        // The Note and Rest Timer rows are not sets; W is a warm-up; F is a
        // working set.
        XCTAssertEqual(bench.sets.map(\.isWarmup).first, true)
        XCTAssertEqual(bench.sets.last?.reps, 4)
        XCTAssertEqual(bench.sets.last?.weightKg, 80)
        XCTAssertFalse(bench.sets.contains { $0.reps == 0 && $0.weightKg == 0 && $0.durationSec == nil })
        let pulldown = try XCTUnwrap(workouts[0].exercises.first { $0.name == "Lat Pulldown" })
        XCTAssertEqual(pulldown.sets.map(\.weightKg), [55, 40]) // D is a working set
        let plank = try XCTUnwrap(workouts[0].exercises.first { $0.name == "Plank" })
        XCTAssertEqual(plank.sets.first?.durationSec, 60)
        XCTAssertEqual(day(workouts[1].date), "2026-03-04")
    }

    /// No unit anywhere in the file, so nothing is built until one is chosen,
    /// and the choice decides the numbers.
    func testStrongsCommaExportAsksForTheUnit() throws {
        let reading = try WorkoutCSV.read(fixture("csv-strong-comma"))
        XCTAssertTrue(reading.needsUnit)
        let pounds = reading.parse(.pounds)
        let kilos = reading.parse(.kilograms)
        let benchLb = try XCTUnwrap(pounds.first?.exercises.first?.sets.first)
        XCTAssertEqual(benchLb.weightKg, WeightUnit.pounds.toKilograms(135), accuracy: 0.0001)
        XCTAssertEqual(kilos.first?.exercises.first?.sets.first?.weightKg, 135)
        // Zero distance and seconds are unused columns, not a 0 m run.
        XCTAssertNil(benchLb.distanceMeters)
        XCTAssertNil(benchLb.durationSec)
    }

    func testHevyNamesItsUnitAndItsSetTypes() throws {
        let reading = try WorkoutCSV.read(fixture("csv-hevy"))
        XCTAssertEqual(reading.source, .hevy)
        let workouts = reading.parse(nil)
        XCTAssertEqual(workouts.map(\.name), ["Morning run", "Push A"]) // oldest first
        let run = try XCTUnwrap(workouts[0].exercises.first?.sets.first)
        XCTAssertEqual(run.distanceMeters ?? 0, 5210, accuracy: 0.001)
        XCTAssertEqual(run.durationSec, 1860)
        let bench = try XCTUnwrap(workouts[1].exercises.first)
        XCTAssertEqual(bench.sets.map(\.isWarmup), [true, false, false])
        XCTAssertEqual(bench.sets[1].rpe, 8)
        XCTAssertEqual(workouts[1].exercises.last?.name, "Triceps Pushdown")
        XCTAssertNil(workouts[1].exercises.last?.equipment)
    }

    func testHevyInPoundsIsConverted() throws {
        let text = """
        "title","start_time","end_time","description","exercise_title","superset_id","exercise_notes","set_index","set_type","weight_lbs","reps","distance_miles","duration_seconds","rpe"
        "A","Oct 1, 2026, 8:28 PM","Oct 1, 2026, 9:10 PM","","Squat (Barbell)",,"",0,"normal",225,5,,,
        "A","Oct 1, 2026, 8:28 PM","Oct 1, 2026, 9:10 PM","","Walk",,"",0,"normal",,,1.5,,
        """
        let workouts = try WorkoutCSV.read(text).parse(nil)
        XCTAssertEqual(workouts.first?.exercises.first?.sets.first?.weightKg ?? 0,
                       WeightUnit.pounds.toKilograms(225), accuracy: 0.0001)
        XCTAssertEqual(workouts.first?.exercises.last?.sets.first?.distanceMeters ?? 0, 2414.016, accuracy: 0.001)
        XCTAssertEqual(day(try XCTUnwrap(workouts.first?.date)), "2026-10-01")
    }

    /// FitNotes says the unit on every row, and one file can mix them.
    func testFitNotesMixesUnitsRowByRow() throws {
        let reading = try WorkoutCSV.read(fixture("csv-fitnotes"))
        XCTAssertEqual(reading.source, .fitNotes)
        let workouts = reading.parse(nil)
        XCTAssertEqual(workouts.count, 2)
        let raise = try XCTUnwrap(workouts[0].exercises.first { $0.name == "Dumbbell Lateral Raise" })
        XCTAssertEqual(raise.sets.first?.weightKg ?? 0, WeightUnit.pounds.toKilograms(25), accuracy: 0.0001)
        XCTAssertEqual(raise.primaryMuscle, "shoulders")
        let run = try XCTUnwrap(workouts[1].exercises.first?.sets.first)
        XCTAssertEqual(run.distanceMeters ?? 0, 3.2 * 1609.344, accuracy: 0.001)
        XCTAssertEqual(run.durationSec, 31 * 60)
    }

    func testAFileFromSomewhereElseIsRefused() {
        XCTAssertThrowsError(try WorkoutCSV.read("Name,Calories\nApple,95\n")) {
            XCTAssertEqual($0 as? WorkoutCSV.Failure, .notRecognised)
        }
        XCTAssertThrowsError(try WorkoutCSV.read("")) {
            XCTAssertEqual($0 as? WorkoutCSV.Failure, .empty)
        }
    }

    func testTheCSVReaderHandlesQuotesBOMAndCRLF() {
        let rows = WorkoutCSV.parse("\u{FEFF}a,b\r\n\"x, \"\"y\"\"\",2\r\n")
        XCTAssertEqual(rows, [["a", "b"], ["x, \"y\"", "2"]])
    }

    func testEquipmentComesOutOfTheName() {
        XCTAssertTrue(WorkoutCSV.splitEquipment("Bench Press (Barbell)") == ("Bench Press", "Barbell"))
        XCTAssertTrue(WorkoutCSV.splitEquipment("Pull Up") == ("Pull Up", nil))
        XCTAssertTrue(WorkoutCSV.splitEquipment("(Odd)") == ("(Odd)", nil))
    }

    // MARK: - Into the store

    @MainActor
    private func context() throws -> ModelContext {
        ModelContext(LiftStore.makeContainer(inMemory: true))
    }

    /// A day already trained is left alone, and the same file twice adds
    /// nothing the second time.
    @MainActor
    func testADayAlreadyLoggedIsLeftAloneAndAReimportAddsNothing() throws {
        let context = try context()
        let workouts = try WorkoutCSV.read(fixture("csv-strong-semicolon")).parse(nil)
        let mine = WorkoutDay(date: workouts[1].date, name: "Mine")
        mine.exercises = [ExerciseEntry(exerciseRefID: "x", name: "My squat", orderIndex: 0)]
        context.insert(mine)
        try context.save()

        let first = WorkoutCSV.apply(workouts, source: .strong, in: context)
        XCTAssertEqual(first.daysAdded, 1)
        XCTAssertEqual(first.daysSkipped, 1)
        XCTAssertGreaterThan(first.setsAdded, 0)
        XCTAssertEqual(mine.exercises.map(\.name), ["My squat"])

        let again = WorkoutCSV.apply(workouts, source: .strong, in: context)
        XCTAssertEqual(again.daysAdded, 0)
        XCTAssertEqual(again.daysSkipped, 2)
    }

    // MARK: - Out

    func testTheExportIsOneRowASetInKilograms() {
        let text = WorkoutCSV.export([
            .init(dayKey: "2026-10-26", workout: "Push, heavy", exercise: "Bench Press", equipment: "Barbell",
                  set: 1, isWarmup: true, side: nil, weightKg: 60, reps: 8, rpe: nil, seconds: nil, distanceMeters: nil),
            .init(dayKey: "2026-10-26", workout: "Push, heavy", exercise: "Split \"Squat\"", equipment: nil,
                  set: 1, isWarmup: false, side: "left", weightKg: 22.5, reps: 10, rpe: 8.5, seconds: nil, distanceMeters: nil),
        ])
        XCTAssertEqual(text, [
            "Date,Workout,Exercise,Equipment,Set,Warmup,Side,Weight (kg),Reps,RPE,Seconds,Distance (m)",
            #"2026-10-26,"Push, heavy",Bench Press,Barbell,1,yes,,60,8,,,"#,
            #"2026-10-26,"Push, heavy","Split ""Squat""",,1,,left,22.5,10,8.5,,"#,
        ].joined(separator: "\n") + "\n")
    }
}
