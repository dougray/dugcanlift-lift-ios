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

    /// Swift reads CR LF as one `Character`, so a header that stopped only at
    /// `"\n"` ran on through the whole file, and its commas outvoted the
    /// header's semicolons.
    func testTheDelimiterIsReadFromTheHeaderLineAloneInACRLFFile() {
        let rows = WorkoutCSV.parse("a;b\r\n\"w,x,y,z\";1\r\n")
        XCTAssertEqual(rows, [["a", "b"], ["w,x,y,z", "1"]])
    }

    /// RPE, seconds and distance are optional on `SetEntry`: a cell the file
    /// leaves empty is nil, never 0. Weight and reps are not optional, so an
    /// empty one is the model's 0, which is its absence.
    func testAnEmptyCellIsReadAsNothing() throws {
        let text = """
        "title","start_time","end_time","description","exercise_title","superset_id","exercise_notes","set_index","set_type","weight_kg","reps","distance_km","duration_seconds","rpe"
        "A","Oct 1, 2026, 8:28 PM","Oct 1, 2026, 9:10 PM","","Pull Up",,"",0,"normal",,10,,,
        "A","Oct 1, 2026, 8:28 PM","Oct 1, 2026, 9:10 PM","","Pull Up",,"",1,"normal",,8,,,0
        """
        let sets = try XCTUnwrap(WorkoutCSV.read(text).parse(nil).first?.exercises.first?.sets)
        XCTAssertNil(sets[0].rpe)
        XCTAssertNil(sets[0].durationSec)
        XCTAssertNil(sets[0].distanceMeters)
        XCTAssertEqual(sets[0].weightKg, 0)
        XCTAssertEqual(sets[0].reps, 10)
        // A 0 the file does write, in a field that can hold nothing, is kept.
        XCTAssertEqual(sets[1].rpe, 0)
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

    /// Two decimals at most, trailing zeros dropped, and the point with them:
    /// 59.999 was written "60." before.
    func testANumberLosesItsPointWithItsZeros() {
        XCTAssertEqual(WorkoutCSV.exportNumber(59.999), "60")
        XCTAssertEqual(WorkoutCSV.exportNumber(60.5), "60.5")
        XCTAssertEqual(WorkoutCSV.exportNumber(60.50001), "60.5")
        XCTAssertEqual(WorkoutCSV.exportNumber(0.25), "0.25")
        XCTAssertEqual(WorkoutCSV.exportNumber(22.75), "22.75")
        XCTAssertEqual(WorkoutCSV.exportNumber(60), "60")
        XCTAssertEqual(WorkoutCSV.exportNumber(100), "100")
        XCTAssertEqual(WorkoutCSV.exportNumber(1000.001), "1000")
        XCTAssertEqual(WorkoutCSV.exportNumber(0), "0")
        XCTAssertEqual(WorkoutCSV.exportNumber(nil), "")
        XCTAssertEqual(WorkoutCSV.exportNumber(.nan), "")
        XCTAssertEqual(WorkoutCSV.exportNumber(.infinity), "")

        let text = WorkoutCSV.export([
            .init(dayKey: "2026-10-26", workout: "", exercise: "Row", equipment: nil, set: 1, isWarmup: false,
                  side: nil, weightKg: 59.999, reps: 5, rpe: 7.5, seconds: nil, distanceMeters: 0.25),
        ])
        XCTAssertEqual(text.split(separator: "\n").last, "2026-10-26,,Row,,1,,,60,5,7.5,,0.25")
    }

    /// Nothing recorded is an empty cell, as LIFT web writes it: nil RPE,
    /// seconds and distance, and weight and reps of 0, which on `SetEntry` is
    /// the absence. A real 0 in an optional field is still written.
    func testBlankStaysBlankOnTheWayOut() {
        let text = WorkoutCSV.export([
            .init(dayKey: "2026-10-26", workout: "", exercise: "Pull Up", equipment: nil, set: 1, isWarmup: false,
                  side: nil, weightKg: 0, reps: 10, rpe: nil, seconds: nil, distanceMeters: nil),
            .init(dayKey: "2026-10-26", workout: "", exercise: "Plank", equipment: nil, set: 1, isWarmup: false,
                  side: nil, weightKg: 0, reps: 0, rpe: 0, seconds: 60, distanceMeters: nil),
        ])
        XCTAssertEqual(text.split(separator: "\n").dropFirst(), [
            "2026-10-26,,Pull Up,,1,,,,10,,,",
            "2026-10-26,,Plank,,1,,,,,0,60,",
        ])
    }

    /// An empty cell goes in as nothing and comes back out as an empty cell,
    /// through the store.
    @MainActor
    func testAnEmptyCellRoundTripsAsAnEmptyCell() throws {
        let context = try context()
        let text = """
        "title","start_time","end_time","description","exercise_title","superset_id","exercise_notes","set_index","set_type","weight_kg","reps","distance_km","duration_seconds","rpe"
        "Pull","Oct 1, 2026, 8:28 PM","Oct 1, 2026, 9:10 PM","","Pull Up",,"",0,"normal",,10,,,
        """
        let workouts = try WorkoutCSV.read(text).parse(nil)
        XCTAssertEqual(WorkoutCSV.apply(workouts, source: .hevy, in: context).setsAdded, 1)
        let exported = WorkoutCSV.export(WorkoutCSV.exportRows(from: context))
        XCTAssertEqual(exported.split(separator: "\n").last, "2026-10-01,Pull,Pull Up,,1,,,,10,,,")
    }
}
