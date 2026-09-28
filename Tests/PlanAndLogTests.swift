import XCTest
import SwiftData
import LiftCore
@testable import Lift

/// The week card's rule: a coach's plan beside this phone's own log
/// (`PlanAndLog`). **LIFT web's `lift/plan-log.test.mjs` is the reference**,
/// case for case, as `PlanSidesTests` ports `plan-sides.test.mjs`.
///
/// Weights are the kilograms this app stores, so the numbers here are read in
/// kilograms and the strings are web's strings with web's numbers. The one
/// thing that is not a straight port is `setText`, which reproduces
/// `SetEntry.display` rather than the browser's own field order -- see
/// `testASetReadsExactlyAsItDoesEverywhereElseInTheApp`.
final class PlanAndLogTests: XCTestCase {

    /* The week everything below sits in: Mon 12 Oct 2026 to Sun 18 Oct 2026.
     * "today" is Thu 15 Oct unless a test says otherwise, so the week has three
     * days behind it, one being lived, and three still ahead -- which is the
     * state this card exists for. */
    private let mon = "2026-10-12"
    private let tue = "2026-10-13"
    private let wed = "2026-10-14"
    private let thu = "2026-10-15"
    private let fri = "2026-10-16"
    private let sat = "2026-10-17"
    private let sun = "2026-10-18"
    private var today: String { thu }

    /// The tests pin one locale only so they can assert a string. The card
    /// itself formats in the reader's own, as `RoadFoodRanking` already decided.
    private let locale = Locale(identifier: "en_US")

    // MARK: Building the two halves

    private func set(_ weight: Double?, _ reps: Int?, rpe: Double? = nil,
                     durationSec: Int? = nil, distanceMeters: Double? = nil,
                     side: SetSide? = nil) -> PlanAndLog.SetValues {
        PlanAndLog.SetValues(weightKg: weight, reps: reps, rpe: rpe,
                             durationSec: durationSec, distanceMeters: distanceMeters,
                             side: side)
    }

    private func lift(_ name: String, _ equipment: String,
                      _ sets: [PlanAndLog.SetValues],
                      eachSide: Bool = false) -> PlanAndLog.Exercise {
        PlanAndLog.Exercise(name: name, equipment: equipment, eachSide: eachSide, sets: sets)
    }

    private func booked(_ date: String, _ name: String,
                        _ exercises: [PlanAndLog.Exercise]) -> PlanAndLog.Booking {
        PlanAndLog.Booking(date: date, name: name, exercises: exercises)
    }

    private func loggedDay(_ date: String, _ name: String,
                           _ exercises: [PlanAndLog.Exercise]) -> PlanAndLog.LoggedDay {
        PlanAndLog.LoggedDay(date: date, name: name, exercises: exercises)
    }

    private func run(_ bookings: [PlanAndLog.Booking], _ days: [PlanAndLog.LoggedDay],
                     today: String? = nil, anchor: String? = nil,
                     unit: WeightUnit = .kilograms) -> PlanAndLog.Result? {
        PlanAndLog.compare(bookings: bookings, logged: days,
                           today: today ?? self.today, anchor: anchor ?? self.today,
                           unit: unit, locale: locale)
    }

    private func day(_ result: PlanAndLog.Result?, _ index: Int) throws -> PlanAndLog.DayRow {
        try XCTUnwrap(result?.days[index])
    }

    private func find(_ result: PlanAndLog.Result?, _ key: String) throws -> PlanAndLog.DayRow {
        try XCTUnwrap(result?.days.first { $0.key == key })
    }

    private func exercise(_ row: PlanAndLog.DayRow,
                          _ prefix: String) throws -> PlanAndLog.ExerciseRow {
        try XCTUnwrap(row.exercises.first { $0.key.hasPrefix(prefix) })
    }

    /* A fixed pair used by several tests: Monday's "Lower A" booked and logged
     * whole, Tuesday's "Upper B" booked and nothing logged, Wednesday free and
     * trained anyway, Friday booked and still ahead. */
    private func weekTraining() -> [PlanAndLog.Booking] {
        [booked(mon, "Lower A", [
            lift("Back Squat", "Barbell", [set(225, 5), set(225, 5), set(245, 3)]),
            lift("Romanian Deadlift", "Barbell",
                 [set(185, 8), set(185, 8), set(185, 8), set(185, 8)]),
            lift("Bulgarian Split Squat", "Dumbbell",
                 [set(40, 8), set(40, 8), set(40, 8)], eachSide: true),
            lift("Overhead Press", "Barbell", [set(95, 8)]),
        ]),
         booked(tue, "Upper B", [lift("Bench Press", "Barbell", [set(185, 5), set(185, 5)])]),
         booked(fri, "Lower B", [
            lift("Front Squat", "Barbell", [set(165, 5), set(165, 5)]),
            lift("Split Squat", "Dumbbell", [set(35, 10), set(35, 10)], eachSide: true),
         ])]
    }

    private func weekWorkouts() -> [PlanAndLog.LoggedDay] {
        [loggedDay(mon, "Lower A", [
            lift("Back Squat", "Barbell", [set(225, 5), set(225, 5), set(245, 2)]),
            lift("Romanian Deadlift", "Barbell", [set(185, 8), set(185, 8), set(185, 6)]),
            lift("Bulgarian Split Squat", "Dumbbell", [
                set(40, 8, side: .left), set(40, 8, side: .left), set(40, 5, side: .left),
                set(40, 8, side: .right), set(40, 8, side: .right)]),
            lift("Leg Press", "Machine", [set(300, 10), set(300, 10), set(300, 10)]),
        ]),
         loggedDay(wed, "Arms", [lift("Barbell Curl", "Barbell", [set(65, 10), set(65, 10)])])]
    }

    // MARK: - A week with a plan and a complete log

    func testAWeekBookedAndLoggedWholeReadsBackAsLoggedLiftByLift() throws {
        let result = run([booked(mon, "Lower A", [
            lift("Back Squat", "Barbell", [set(225, 5), set(225, 5), set(245, 3)])])],
                         [loggedDay(mon, "Lower A", [
            lift("Back Squat", "Barbell", [set(225, 5), set(225, 5), set(245, 3)])])])
        XCTAssertEqual(result?.head, "Booked 1 day, 12–18 Oct · logged 1")
        XCTAssertEqual(PlanAndLog.lines(result), [
            "Booked 1 day, 12–18 Oct · logged 1",
            "Mon 12 Oct · Lower A · logged",
            "Back Squat (Barbell)",
            "Asked 225 x 5 · 225 x 5 · 245 x 3",
            "Logged 225 x 5 · 225 x 5 · 245 x 3",
            PlanAndLog.footer,
        ])
    }

    // MARK: - A partial log

    func testAPartialLogPrintsBothRowsAndAlignsNothing() throws {
        let result = run(weekTraining(), weekWorkouts())
        let monday = try day(result, 0)
        XCTAssertEqual(monday.state, .logged)
        let deadlift = try exercise(monday, "romanian")
        XCTAssertEqual(deadlift.countLine, "Asked 4 sets · logged 3")
        XCTAssertEqual(deadlift.asked?.text, "185 x 8 · 185 x 8 · 185 x 8 · 185 x 8")
        XCTAssertEqual(deadlift.logged?.text, "185 x 8 · 185 x 8 · 185 x 6")
    }

    func testALiftThePlanAskedForAndTheLogDoesNotHoldReadsNotLogged() throws {
        let press = try exercise(try day(run(weekTraining(), weekWorkouts()), 0), "overhead press")
        XCTAssertEqual(press.title, "Overhead Press (Barbell) · not logged")
        XCTAssertNil(press.asked,
                     "a lift nothing was logged against is one line, not a recital")
        XCTAssertNil(press.logged)
    }

    func testALiftNobodyAskedForIsCountedAgainstNothingUnderAlsoLogged() throws {
        XCTAssertEqual(try day(run(weekTraining(), weekWorkouts()), 0).alsoLogged.map(\.text),
                       ["Leg Press (Machine) · 3 sets"])
    }

    func testABookedDayInThePastWithNothingLoggedReadsNotLoggedNeverMissed() throws {
        let tuesday = try find(run(weekTraining(), weekWorkouts()), tue)
        XCTAssertEqual(tuesday.state, .notLogged)
        XCTAssertEqual(tuesday.text, "Tue 13 Oct · Upper B · not logged")
        XCTAssertEqual(tuesday.exercises.map(\.title), ["Bench Press (Barbell) · not logged"])
        XCTAssertEqual(tuesday.exercises.map(\.asked), [nil],
                       "the day is one tap away and its own booking still holds every set")
    }

    func testTheHeadCountsTheWeekWithoutGradingIt() throws {
        let result = run(weekTraining(), weekWorkouts())
        XCTAssertEqual(result?.head,
                       "Booked 3 days, 12–18 Oct · logged 1 · 1 to do · 1 other day logged")
        XCTAssertEqual(result?.counts, PlanAndLog.Counts(booked: 3, logged: 1, notLogged: 1,
                                                        toDo: 1, other: 1))
    }

    // MARK: - Days still ahead

    func testABookedDayThatHasNotHappenedYetIsToDoNotAnAbsence() throws {
        let friday = try find(run(weekTraining(), weekWorkouts()), fri)
        XCTAssertEqual(friday.state, .toDo)
        XCTAssertEqual(friday.text, "Fri 16 Oct · Lower B · to do")
        XCTAssertFalse(friday.openable, "Train cannot be moved to a day that has not happened")
    }

    func testADayStillAheadPrintsWhatItAsksForBecauseNowhereElseCan() throws {
        let friday = try find(run(weekTraining(), weekWorkouts()), fri)
        XCTAssertEqual(friday.exercises.map(\.title),
                       ["Front Squat (Barbell)", "Split Squat (Dumbbell) · each side"])
        XCTAssertEqual(friday.exercises[0].asked?.text, "165 x 5 · 165 x 5")
        XCTAssertEqual(friday.exercises[1].asked?.text, "35 x 10 · 35 x 10 each side")
        XCTAssertNil(friday.exercises[0].logged)
        XCTAssertEqual(friday.exercises.map(\.state), [.toDo, .toDo])
    }

    func testADayStillAheadIsNeverARowOfNoughts() throws {
        let friday = try find(run(weekTraining(), weekWorkouts()), fri)
        XCTAssertEqual(friday.exercises[1].sideLine, "Each side · L 2 · R 2")
        XCTAssertNil(friday.exercises[0].sideLine)
        XCTAssertNil(friday.exercises[0].countLine)
    }

    func testTodayIsStillToDoUntilSomethingIsLoggedAgainstIt() throws {
        let result = run([booked(thu, "Upper A",
                                [lift("Bench Press", "Barbell", [set(185, 5)])])], [])
        XCTAssertEqual(try day(result, 0).state, .toDo)
        XCTAssertEqual(try day(result, 0).text, "Thu 15 Oct · Upper A · to do")
        XCTAssertTrue(try day(result, 0).openable)
    }

    func testAWeekBookedEntirelyInTheDaysAheadDoesNotOpenWithANought() {
        let result = run([booked(fri, "Lower B", [lift("Front Squat", "Barbell", [set(165, 5)])]),
                          booked(sat, "Upper B", [lift("Bench Press", "Barbell", [set(185, 5)])])],
                         [])
        XCTAssertEqual(result?.head, "Booked 2 days, 12–18 Oct · 2 to do")
    }

    func testAWeekThatIsOverSaysWhatItCountedWhateverItCounted() throws {
        let result = run([booked(mon, "Lower A", [lift("Back Squat", "Barbell", [set(225, 5)])])],
                         [], today: "2026-10-25", anchor: thu)
        XCTAssertEqual(result?.head, "Booked 1 day, 12–18 Oct · logged 0")
        XCTAssertEqual(try day(result, 0).state, .notLogged)
    }

    // MARK: - A session done on a different day from the one planned

    func testASessionLiftedTheDayAfterTheOneItWasBookedForIsTwoRowsAdjacent() {
        let result = run(
            [booked(tue, "Upper B", [lift("Bench Press", "Barbell", [set(185, 5), set(185, 5)])])],
            [loggedDay(wed, "Upper B", [lift("Bench Press", "Barbell",
                                             [set(185, 5), set(185, 5)])])])
        XCTAssertEqual(result?.days.map(\.text), [
            "Tue 13 Oct · Upper B · not logged",
            "Wed 14 Oct · Upper B · not booked",
        ])
        XCTAssertEqual(result?.head, "Booked 1 day, 12–18 Oct · logged 0 · 1 other day logged")
    }

    func testNothingClaimsTheMovedSessionAnsweredTheBooking() throws {
        let result = run([booked(tue, "Upper B", [lift("Bench Press", "Barbell", [set(185, 5)])])],
                         [loggedDay(wed, "Upper B",
                                    [lift("Bench Press", "Barbell", [set(185, 5)])])])
        let wednesday = try find(result, wed)
        XCTAssertEqual(wednesday.state, .notBooked)
        XCTAssertEqual(wednesday.exercises, [],
                       "a day nobody booked is held against no prescription")
        XCTAssertEqual(wednesday.alsoLogged.map(\.text), ["Bench Press (Barbell) · 1 set"])
        XCTAssertEqual(result?.counts.logged, 0)
    }

    func testADayOfYourOwnInsideAWeekNobodyBookedIsNotACardAtAll() {
        XCTAssertNil(run([], weekWorkouts()))
    }

    // MARK: - Sides

    func testAnEachSideLiftShortOnOneSideReadsThreeOverThreeAndTwoOverThree() throws {
        let split = try exercise(try day(run(weekTraining(), weekWorkouts()), 0), "bulgarian")
        XCTAssertEqual(split.title, "Bulgarian Split Squat (Dumbbell) · each side")
        XCTAssertEqual(split.sideLine, "L 3/3 · R 2/3")
        XCTAssertEqual(split.asked?.text, "40 x 8 · 40 x 8 · 40 x 8 each side")
        XCTAssertEqual(split.logged?.text, "L 40 x 8 · 40 x 8 · 40 x 5   R 40 x 8 · 40 x 8")
    }

    /// Not a second reading of the same rule: `Prescription.targetsLabel` **is**
    /// the exercise header in the day editor, called with the same argument.
    func testTheSideCountsAreTheSessionHeadersOwnNotASecondReading() throws {
        let askedSets = [set(40, 8), set(40, 8), set(40, 8)]
        let loggedSets = [set(40, 8, side: .left), set(40, 8, side: .left),
                          set(40, 5, side: .left), set(40, 8, side: .right),
                          set(40, 8, side: .right)]
        let result = run([booked(mon, "Lower A",
                                 [lift("Split Squat", "Dumbbell", askedSets, eachSide: true)])],
                         [loggedDay(mon, "Lower A", [lift("Split Squat", "Dumbbell", loggedSets)])])
        let header = Prescription(eachSide: true,
                                 sets: askedSets.map { CoachPrescribedSet(side: $0.side) })
            .targetsLabel(logged: loggedSets.map(\.side))
        XCTAssertEqual(try day(result, 0).exercises[0].sideLine, header)
        XCTAssertEqual(header, "L 3/3 · R 2/3")
    }

    func testOverIsShownAsOverNeverCapped() throws {
        let result = run(
            [booked(mon, "Lower A", [lift("Split Squat", "Dumbbell",
                                          [set(40, 8), set(40, 8), set(40, 8)], eachSide: true)])],
            [loggedDay(mon, "Lower A", [lift("Split Squat", "Dumbbell", [
                set(40, 8, side: .left), set(40, 8, side: .left), set(40, 8, side: .left),
                set(40, 8, side: .left), set(40, 8, side: .right), set(40, 8, side: .right),
                set(40, 8, side: .right)])])])
        XCTAssertEqual(try day(result, 0).exercises[0].sideLine, "L 4/3 · R 3/3")
    }

    func testAnEachSideExercisesAskIsTwiceItsTuples() throws {
        let result = run(
            [booked(mon, "Lower A", [lift("Split Squat", "Dumbbell",
                                          [set(40, 8), set(40, 8), set(40, 8)], eachSide: true)])],
            [loggedDay(mon, "Lower A", [lift("Split Squat", "Dumbbell",
                                             [set(40, 8, side: .left)])])])
        XCTAssertEqual(try day(result, 0).exercises[0].sideLine, "L 1/3 · R 0/3")
    }

    func testANamedSideOnALiftThatIsNotEachSideIsOneSetOnThatSide() throws {
        let result = run(
            [booked(mon, "Lower A", [lift("Calf Raise", "Machine",
                                          [set(90, 12), set(90, 12, side: .left)])])],
            [loggedDay(mon, "Lower A", [lift("Calf Raise", "Machine",
                                             [set(90, 12), set(90, 12, side: .left)])])])
        let row = try day(result, 0).exercises[0]
        XCTAssertEqual(row.title, "Calf Raise (Machine)", "not each side")
        XCTAssertEqual(row.sideLine, "L 1/1 · 1/1 both")
        XCTAssertEqual(row.asked?.text, "L 90 x 12   Both 90 x 12")
    }

    func testAPlanWithNoSidesProducesNoSideLineAtAll() throws {
        let result = run(
            [booked(mon, "Lower A", [lift("Back Squat", "Barbell", [set(225, 5), set(225, 5)])])],
            [loggedDay(mon, "Lower A", [lift("Back Squat", "Barbell",
                                             [set(225, 5), set(225, 5)])])])
        XCTAssertNil(try day(result, 0).exercises[0].sideLine)
    }

    func testSidesLoggedAgainstAPlanThatAskedForNoneAreStillSaid() throws {
        let result = run(
            [booked(mon, "Lower A", [lift("Calf Raise", "Machine", [set(90, 12), set(90, 12)])])],
            [loggedDay(mon, "Lower A", [lift("Calf Raise", "Machine",
                                             [set(90, 12, side: .left),
                                              set(90, 12, side: .right)])])])
        XCTAssertEqual(try day(result, 0).exercises[0].sideLine, "L 1 · R 1")
    }

    func testSetsLoggedBeforePerSideLoggingAreABothGroupBesideTheTwoLimbs() throws {
        let result = run(
            [booked(mon, "Lower A", [lift("Calf Raise", "Machine", [set(90, 12)])])],
            [loggedDay(mon, "Lower A", [lift("Calf Raise", "Machine",
                                             [set(90, 12), set(90, 12, side: .left),
                                              set(90, 12, side: .right)])])])
        XCTAssertEqual(try day(result, 0).exercises[0].logged?.text,
                       "L 90 x 12   R 90 x 12   Both 90 x 12")
    }

    /// One sentence, one place: the card and the exercise header in the day
    /// editor read the same function, so they cannot drift.
    @MainActor
    func testThePlainSideCountIsTheExerciseHeadersOwnSentence() {
        let entry = ExerciseEntry(exerciseRefID: "x", name: "Calf Raise", orderIndex: 0)
        entry.sets = [SetEntry(orderIndex: 0, side: .left), SetEntry(orderIndex: 1, side: .left),
                      SetEntry(orderIndex: 2, side: .right), SetEntry(orderIndex: 3)]
        XCTAssertEqual(entry.perSideCountLabel, "L 2 · R 1 · 1 both")
        XCTAssertEqual(SetSide.countsLabel(of: entry.sets.map(\.side)), entry.perSideCountLabel)
    }

    // MARK: - A lift substituted

    func testASubstitutionIsOnePairOnNameAloneLabelled() throws {
        let result = run(
            [booked(mon, "Lower A", [lift("Bench Press", "Barbell", [set(185, 5), set(185, 5)])])],
            [loggedDay(mon, "Lower A", [lift("Bench Press", "Smith machine",
                                             [set(185, 5), set(185, 5)])])])
        let row = try day(result, 0).exercises[0]
        XCTAssertEqual(row.state, .logged)
        XCTAssertEqual(row.substitution, "Asked Barbell · logged Smith machine")
        XCTAssertEqual(try day(result, 0).alsoLogged, [],
                       "a substitution is one row, not two")
    }

    func testAnExactNameAndEquipmentMatchAlwaysWinsOverANameOnlyOne() throws {
        let result = run(
            [booked(mon, "Pull", [lift("Lat Pulldown", "Cable", [set(120, 10)]),
                                  lift("Lat Pulldown", "Machine", [set(140, 10)])])],
            [loggedDay(mon, "Pull", [lift("Lat Pulldown", "Machine", [set(140, 10)]),
                                     lift("Lat Pulldown", "Cable", [set(120, 10)])])])
        let rows = try day(result, 0).exercises
        XCTAssertEqual(rows[0].logged?.text, "120 x 10")
        XCTAssertEqual(rows[1].logged?.text, "140 x 10")
        XCTAssertNil(rows[0].substitution)
        XCTAssertNil(rows[1].substitution)
    }

    func testALiftWithNoEquipmentEitherSideSaysSoInWords() throws {
        let result = run(
            [booked(mon, "Core", [lift("Plank", "", [set(nil, nil, durationSec: 60)])])],
            [loggedDay(mon, "Core", [lift("Plank", "Band", [set(nil, nil, durationSec: 45)])])])
        XCTAssertEqual(try day(result, 0).exercises[0].substitution,
                       "Asked no equipment · logged Band")
    }

    // MARK: - Pooling

    func testTheSameLiftAskedForTwiceInADayIsOnePrescriptionOfMoreSets() throws {
        let result = run(
            [booked(mon, "Lower A", [lift("Back Squat", "Barbell", [set(225, 5)]),
                                     lift("Back Squat", "Barbell", [set(245, 3)])])],
            [loggedDay(mon, "Lower A", [lift("Back Squat", "Barbell",
                                             [set(225, 5), set(245, 3)])])])
        XCTAssertEqual(try day(result, 0).exercises.count, 1)
        XCTAssertEqual(try day(result, 0).exercises[0].asked?.text, "225 x 5 · 245 x 3")
    }

    func testTheSameLiftLoggedTwiceInADayPoolsToo() throws {
        let result = run(
            [booked(mon, "Lower A", [lift("Back Squat", "Barbell", [set(225, 5), set(245, 3)])])],
            [loggedDay(mon, "Lower A", [lift("Back Squat", "Barbell", [set(225, 5)]),
                                        lift("Back Squat", "Barbell", [set(245, 3)])])])
        XCTAssertEqual(try day(result, 0).exercises[0].logged?.text, "225 x 5 · 245 x 3")
        XCTAssertEqual(try day(result, 0).alsoLogged, [])
    }

    func testTwoSessionsBookedOnOneDayAreOneDaysAsk() throws {
        let result = run(
            [booked(mon, "Lower A", [lift("Back Squat", "Barbell", [set(225, 5)])]),
             booked(mon, "Accessories", [lift("Calf Raise", "Machine", [set(90, 12)])])],
            [])
        XCTAssertEqual(try day(result, 0).text, "Mon 12 Oct · Lower A · Accessories · not logged")
        XCTAssertEqual(result?.counts.booked, 1, "a day a coach booked twice is one day")
    }

    func testABookedDayWhoseOnlyLogIsEmptyHasNothingLoggedAgainstIt() {
        let result = run(
            [booked(mon, "Lower A", [lift("Back Squat", "Barbell", [set(225, 5)])])],
            [loggedDay(mon, "", [])])
        XCTAssertEqual(result?.days.first?.state, .notLogged)
        XCTAssertEqual(result?.days.count, 1,
                       "an empty day is not an \"other day logged\" either")
    }

    // MARK: - Blank stays blank

    func testBlankStaysBlank() {
        XCTAssertEqual(PlanAndLog.setText(set(nil, 5), unit: .kilograms), "5 reps")
        XCTAssertEqual(PlanAndLog.setText(set(225, nil), unit: .kilograms), "225 kg")
        XCTAssertEqual(PlanAndLog.setText(set(nil, nil), unit: .kilograms), "as written")
        XCTAssertEqual(PlanAndLog.setText(set(nil, nil, durationSec: 600,
                                              distanceMeters: 1600), unit: .kilograms),
                       "10:00 1.60 km")
        XCTAssertEqual(PlanAndLog.setText(set(nil, nil, durationSec: 45), unit: .kilograms),
                       "0:45")
        XCTAssertEqual(PlanAndLog.setText(set(225, 5, rpe: 8), unit: .kilograms), "225 x 5 @8")
    }

    func testAConditioningPieceKeepsItsBlanksThroughTheCard() throws {
        let result = run(
            [booked(mon, "Conditioning", [lift("Row", "Machine",
                                               [set(nil, nil, durationSec: 600,
                                                    distanceMeters: 1600)])])],
            [loggedDay(mon, "Conditioning", [lift("Row", "Machine",
                                                  [set(nil, nil, durationSec: 540,
                                                       distanceMeters: 1600)])])])
        let row = try day(result, 0).exercises[0]
        XCTAssertEqual(row.asked?.text, "10:00 1.60 km")
        XCTAssertEqual(row.logged?.text, "9:00 1.60 km")
    }

    /// The one place this card deliberately does not copy the browser: a set is
    /// spelled the way `SetEntry.display` spells it -- the one sentence the day
    /// editor, a day summary and a widget already use, pinned by
    /// `SetDisplayParityTests`. A card comparing two rows printed by two
    /// different formatters would be comparing two different sentences.
    @MainActor
    func testASetReadsExactlyAsItDoesEverywhereElseInTheApp() {
        let cases: [(Double, Int, Double?, Int?, Double?)] = [
            (100, 5, nil, nil, nil),
            (100, 0, nil, nil, nil),
            (0, 6, nil, nil, nil),
            (100, 5, 8, nil, nil),
            (100, 5, 7.5, 45, 400),
            (0, 0, nil, 600, 1600),
            (62.5, 8, nil, nil, nil),
        ]
        for (weight, reps, rpe, duration, distance) in cases {
            for unit in WeightUnit.allCases {
                let entry = SetEntry(orderIndex: 0, weightKg: weight, reps: reps, rpe: rpe,
                                     durationSec: duration, distanceMeters: distance)
                XCTAssertEqual(PlanAndLog.setText(PlanAndLog.logged(entry), unit: unit),
                               entry.display(unit: unit, includingSide: false),
                               "\(weight) x \(reps) in \(unit)")
            }
        }
    }

    /// Both rows come from one source in one unit, so a card cannot read
    /// kilograms above pounds. Kilograms are the only unit stored; the
    /// conversion happens at display and nowhere else.
    func testBothRowsReadInTheReadersOwnUnitFromOneStoredUnit() throws {
        let hundred = [set(100, 5)]
        let result = run([booked(mon, "Lower A", [lift("Back Squat", "Barbell", hundred)])],
                         [loggedDay(mon, "Lower A", [lift("Back Squat", "Barbell", hundred)])],
                         unit: .pounds)
        let row = try day(result, 0).exercises[0]
        XCTAssertEqual(row.asked?.text, "220.5 x 5")
        XCTAssertEqual(row.logged?.text, "220.5 x 5")
    }

    // MARK: - The week

    func testTheWeekRunsMondayToSundayWhicheverDayItIsAnchoredOn() {
        XCTAssertEqual(PlanAndLog.weekOf(mon).from, mon)
        XCTAssertEqual(PlanAndLog.weekOf(mon).to, sun)
        XCTAssertEqual(PlanAndLog.weekOf(thu).from, mon)
        XCTAssertEqual(PlanAndLog.weekOf(sun).from, mon)
        XCTAssertEqual(PlanAndLog.weekOf(sun).to, sun)
        XCTAssertEqual(PlanAndLog.weekOf("2026-10-19").from, "2026-10-19")
        XCTAssertEqual(PlanAndLog.weekOf("2026-10-19").to, "2026-10-25")
        XCTAssertEqual(PlanAndLog.dayKeys(of: thu),
                       [mon, tue, wed, thu, fri, sat, sun])
    }

    func testAWeekThatCrossesAMonthSaysBothMonths() {
        XCTAssertEqual(PlanAndLog.rangeText(from: "2026-09-28", to: "2026-10-04",
                                            locale: locale), "28 Sep–4 Oct")
        XCTAssertEqual(PlanAndLog.rangeText(from: mon, to: sun, locale: locale), "12–18 Oct")
        XCTAssertEqual(PlanAndLog.rangeText(from: mon, to: mon, locale: locale), "12 Oct")
    }

    func testOnlyTheAnchoredWeekIsRead() {
        XCTAssertNil(run([booked("2026-10-05", "Lower A",
                                 [lift("Back Squat", "Barbell", [set(225, 5)])])], []))
        let back = run([booked("2026-10-05", "Lower A",
                               [lift("Back Squat", "Barbell", [set(225, 5)])])],
                       [], anchor: "2026-10-05")
        XCTAssertEqual(back?.head, "Booked 1 day, 5–11 Oct · logged 0")
    }

    func testADayRowSaysWhichDayItIsBecauseAWeekCanCrossAMonth() throws {
        let result = run([booked("2026-10-01", "Lower A",
                                 [lift("Back Squat", "Barbell", [set(225, 5)])])],
                         [], today: "2026-10-01", anchor: "2026-10-01")
        XCTAssertEqual(try day(result, 0).text, "Thu 1 Oct · Lower A · to do")
        XCTAssertEqual(result?.head, "Booked 1 day, 28 Sep–4 Oct · 1 to do")
    }

    func testTheArrowsMoveBetweenWeeksACoachBookedNeverIntoAnEmptyOne() {
        // Two empty weeks sit between 12 Oct and 2 Nov, and the arrow skips
        // both -- a card that vanished on the way would take its own arrows
        // with it.
        let dates = ["2026-09-28", mon, "2026-11-02"]
        XCTAssertEqual(PlanAndLog.adjacentWeek(bookedDates: dates, from: mon, direction: 1),
                       "2026-11-02")
        XCTAssertEqual(PlanAndLog.adjacentWeek(bookedDates: dates, from: mon, direction: -1),
                       "2026-09-28")
        XCTAssertNil(PlanAndLog.adjacentWeek(bookedDates: dates, from: "2026-09-28",
                                             direction: -1))
        XCTAssertNil(PlanAndLog.adjacentWeek(bookedDates: dates, from: "2026-11-02",
                                             direction: 1))
        XCTAssertNil(PlanAndLog.adjacentWeek(bookedDates: [], from: mon, direction: 1))
    }

    func testAWeekReachedByAnArrowIsTheSameCardAsOneReachedByADate() {
        let bookings = [booked("2026-09-28", "Lower A",
                               [lift("Back Squat", "Barbell", [set(225, 5)])])]
        let back = PlanAndLog.adjacentWeek(bookedDates: ["2026-09-28"], from: mon, direction: -1)
        XCTAssertEqual(run(bookings, [], anchor: back)?.head,
                       "Booked 1 day, 28 Sep–4 Oct · logged 0")
    }

    // MARK: - A week with no plan at all

    func testAPlanNeverAcceptedIsNoCardAndNoExplanation() {
        XCTAssertNil(run([], []))
        XCTAssertTrue(PlanAndLog.lines(nil).isEmpty)
    }

    func testAWeekWithNoBookingIsNoCardHoweverMuchWasLoggedInIt() {
        XCTAssertNil(run([booked("2026-10-05", "Lower A",
                                 [lift("Back Squat", "Barbell", [set(225, 5)])])],
                         weekWorkouts()),
                     "your own training is never held up against a plan nobody wrote")
    }

    // MARK: - Who sent it

    private func signed(_ bookings: [PlanAndLog.Booking],
                        anchor: String? = nil) throws -> String {
        let result = try XCTUnwrap(run(bookings, [], anchor: anchor))
        return PlanAndLog.sentBy(result, bookings: bookings)
    }

    /// Web's own case: the week is signed the way the prescribed card signs a
    /// session, and a plan that named nobody signs it "From your coach".
    func testTheWeekIsSignedTheWayThePrescribedCardSignsASession() throws {
        let squat = lift("Back Squat", "Barbell", [set(225, 5)])
        XCTAssertEqual(
            try signed([PlanAndLog.Booking(date: mon, name: "Lower A",
                                           coachName: "Doug", exercises: [squat])]),
            "From Doug")
        XCTAssertEqual(
            try signed([PlanAndLog.Booking(date: mon, name: "Lower A",
                                           coachName: nil, exercises: [squat])]),
            PlanAndLog.noCoachName)
        XCTAssertEqual(PlanAndLog.noCoachName, "From your coach")
    }

    /// A week booked before a booking kept a name at all reads exactly as it
    /// read then: nil on every row, and the fallback sentence.
    func testAWeekBookedBeforeANameWasKeptReadsAsItAlwaysDid() throws {
        XCTAssertEqual(try signed(weekTraining()), PlanAndLog.noCoachName,
                       "the helper builds bookings with no name, as a pre-V9 row has")
    }

    /// Two coaches in one week are both named, in the order the week meets
    /// them, joined with web's separator. A plan that named nobody adds no
    /// voice: it says nothing about who sent the week rather than saying
    /// somebody else did.
    func testTwoCoachesInOneWeekAreBothNamedAndANamelessPlanAddsNothing() throws {
        let squat = lift("Back Squat", "Barbell", [set(225, 5)])
        let bookings = [
            PlanAndLog.Booking(date: mon, name: "Lower A", coachName: "Doug",
                               exercises: [squat]),
            PlanAndLog.Booking(date: wed, name: "Upper A", coachName: "Dana",
                               exercises: [squat]),
            PlanAndLog.Booking(date: fri, name: "Lower B", coachName: nil,
                               exercises: [squat]),
        ]
        XCTAssertEqual(try signed(bookings), "From Doug · Dana")
    }

    /// One coach who booked three days is one name.
    func testOneCoachWhoBookedThreeDaysIsOneName() throws {
        let squat = lift("Back Squat", "Barbell", [set(225, 5)])
        let bookings = [mon, wed, fri].map {
            PlanAndLog.Booking(date: $0, name: "Lower A", coachName: "Doug",
                               exercises: [squat])
        }
        XCTAssertEqual(try signed(bookings), "From Doug")
    }

    /// Only this week signs this week. A coach who booked last week does not
    /// put their name on a week they wrote nothing for.
    func testOnlyTheWeekOnScreenSignsIt() throws {
        let squat = lift("Back Squat", "Barbell", [set(225, 5)])
        let bookings = [
            PlanAndLog.Booking(date: "2026-10-05", name: "Lower A", coachName: "Dana",
                               exercises: [squat]),
            PlanAndLog.Booking(date: mon, name: "Lower A", coachName: "Doug",
                               exercises: [squat]),
        ]
        XCTAssertEqual(try signed(bookings), "From Doug")
        XCTAssertEqual(try signed(bookings, anchor: "2026-10-07"), "From Dana")
    }

    /// `n` is free text from another person's app. A name padded, or carrying
    /// a line break, is one line with single spaces in it -- what the browser
    /// gets from HTML folding whitespace in a `<p>`, which a `Text` does not.
    /// Nothing is cut: how long a line the card gives it is the view's rule.
    func testALongOrMultiLineNameIsOneLineAndIsNotCut() throws {
        let squat = lift("Back Squat", "Barbell", [set(225, 5)])
        let long = String(repeating: "Dana Whitfield-Fotheringay ", count: 12)
            .trimmingCharacters(in: .whitespaces)
        XCTAssertEqual(
            try signed([PlanAndLog.Booking(date: mon, name: "Lower A", coachName: long,
                                           exercises: [squat])]),
            "From " + long)

        let broken = try signed([PlanAndLog.Booking(
            date: mon, name: "Lower A", coachName: "  Dana\nWhitfield\t\tStrength  ",
            exercises: [squat])])
        XCTAssertEqual(broken, "From Dana Whitfield Strength")
        XCTAssertFalse(broken.contains("\n"), "a name cannot add a line to the card")
    }

    /// Who sent a week is a fact about the plans, not a figure about the week:
    /// it is not on `Result` (whose members
    /// `testNothingHereAggregatesAWeekIntoAScore` names) and not in `lines`,
    /// which is the list the line discipline is held to. Web keeps it out of
    /// both for the same reason.
    func testTheSignatureIsNotPartOfTheWeekItSigns() throws {
        let squat = lift("Back Squat", "Barbell", [set(225, 5)])
        let bookings = [PlanAndLog.Booking(date: mon, name: "Lower A", coachName: "Doug",
                                           exercises: [squat])]
        let result = try XCTUnwrap(run(bookings, []))
        XCTAssertFalse(PlanAndLog.lines(result).contains { $0.contains("Doug") })
    }

    // MARK: - Warmups

    /// Warmups are excluded on both sides -- a plan never prescribes one, and
    /// counting them would turn a proper warm up into "Asked 2 sets · logged
    /// 4". `SetEntry.isWarmup` is its own column here, so unlike the browser
    /// and the share link there are no flag bits to mask; a warmup **on a
    /// side** is still a warmup, which is the case `flags == 1` got wrong on the
    /// wire.
    @MainActor
    func testWarmupsAreExcludedFromTheCountsOnBothSidesIncludingASidedOne() throws {
        let context = ModelContext(LiftStore.makeContainer(inMemory: true))
        let day = WorkoutDay(date: try XCTUnwrap(DayKey.date(from: mon)), name: "Lower A")
        context.insert(day)
        let entry = ExerciseEntry(exerciseRefID: "x", name: "Back Squat", orderIndex: 0,
                                  equipment: "Barbell")
        entry.sets = [
            SetEntry(orderIndex: 0, weightKg: 95, reps: 5, isWarmup: true),
            SetEntry(orderIndex: 1, weightKg: 95, reps: 5, isWarmup: true, side: .left),
            SetEntry(orderIndex: 2, weightKg: 225, reps: 5),
            SetEntry(orderIndex: 3, weightKg: 225, reps: 5),
        ]
        day.exercises = [entry]
        try context.save()

        let result = run([booked(mon, "Lower A", [lift("Back Squat", "Barbell",
                                                       [set(225, 5), set(225, 5)])])],
                         [PlanAndLog.loggedDay(day)])
        let row = try XCTUnwrap(result?.days.first?.exercises.first)
        XCTAssertEqual(row.logged?.text, "225 x 5 · 225 x 5")
        XCTAssertNil(row.countLine, "two working sets asked, two logged")
        XCTAssertNil(row.sideLine, "the only sided set was a warmup")
    }

    @MainActor
    func testALiftThatWasAllWarmupsIsNotALiftThatWasLogged() throws {
        let context = ModelContext(LiftStore.makeContainer(inMemory: true))
        let day = WorkoutDay(date: try XCTUnwrap(DayKey.date(from: mon)), name: "Lower A")
        context.insert(day)
        let squat = ExerciseEntry(exerciseRefID: "x", name: "Back Squat", orderIndex: 0,
                                  equipment: "Barbell")
        squat.sets = [SetEntry(orderIndex: 0, weightKg: 225, reps: 5)]
        let treadmill = ExerciseEntry(exerciseRefID: "y", name: "Treadmill", orderIndex: 1,
                                      equipment: "Machine")
        treadmill.sets = [SetEntry(orderIndex: 0, isWarmup: true, durationSec: 300)]
        day.exercises = [squat, treadmill]
        try context.save()

        let result = run([booked(mon, "Lower A", [lift("Back Squat", "Barbell", [set(225, 5)])])],
                         [PlanAndLog.loggedDay(day)])
        XCTAssertEqual(result?.days.first?.alsoLogged, [])
    }

    // MARK: - The line discipline

    /* Coach web's list, word for word, plus the words this screen could reach
     * for and Coach's could not. Coach reads about somebody else and can only
     * patronise them by accident; this reads about the person holding the
     * phone, which is where a training app turns into a scolding one. */
    private let forbidden = ["should", "fix", "warning", "target", "too ", "concern",
                             "missed", "skipped", "failed", "poor", "behind", "compliance",
                             "adherence", "streak", "%"]

    private let forbiddenHere = ["score", "grade", "percent", "rate", "average",
                                 "well done", "good job", "great work", "keep it up",
                                 "nice work", "on track", "off track", "slack", "lazy",
                                 "proud", "ashamed", "congrat", "deserve", "reward",
                                 "excuse", "must ", "need to", "make up", "catch up",
                                 "you did not", "you have not", "perfect week", "consistency"]

    /* Every state the card has, in one week: a day booked and logged whole, a
     * day booked and logged in part, a day booked with nothing logged, a day
     * still ahead, a day logged that nothing was booked for; and a matched
     * lift, a substituted one, one short on a side, one short on sets, one not
     * logged at all and one nobody asked for. */
    private func everyState() -> PlanAndLog.Result? {
        var bookings = weekTraining()
        bookings.append(booked(sat, "Upper A",
                               [lift("Bench Press", "Barbell", [set(185, 5)])]))
        bookings[0].exercises.append(lift("Bench Press", "Barbell", [set(185, 5)]))
        var days = weekWorkouts()
        days[0].exercises.append(lift("Bench Press", "Smith machine", [set(185, 5)]))
        return run(bookings, days)
    }

    func testNothingInThisCardTellsALifterWhatToDo() {
        let every = PlanAndLog.lines(everyState()).joined(separator: " · ").lowercased()
        XCTAssertGreaterThan(every.count, 400, "the fixture should exercise the whole card")
        for word in forbidden + forbiddenHere {
            XCTAssertFalse(every.contains(word), "\"\(word)\" reached a screen: \(every)")
        }
    }

    func testEveryStateTheCardHasIsInThatFixture() throws {
        let result = try XCTUnwrap(everyState())
        XCTAssertEqual(Set(result.days.map(\.state)), [.logged, .notBooked, .notLogged, .toDo])
        XCTAssertEqual(Set(result.days.flatMap { $0.exercises.map(\.state) }),
                       [.logged, .notLogged, .toDo])
        XCTAssertTrue(result.days.contains { !$0.alsoLogged.isEmpty }, "a lift nobody asked for")
        XCTAssertTrue(result.days.contains { $0.exercises.contains { $0.substitution != nil } },
                      "a substitution")
        XCTAssertTrue(result.days.contains { $0.exercises.contains { $0.sideLine != nil } },
                      "a side line")
        XCTAssertTrue(result.days.contains { $0.exercises.contains { $0.countLine != nil } },
                      "a count line")
    }

    func testNothingHereAggregatesAWeekIntoAScore() throws {
        let result = try XCTUnwrap(everyState())

        // Counts hang off the week the card is looking at, and there is nothing
        // above them: no all-time figure, no trend, nothing carried to next
        // week.
        XCTAssertEqual(Mirror(reflecting: result).children.compactMap(\.label).sorted(),
                       ["counts", "days", "footer", "from", "head", "range", "to"])
        XCTAssertEqual(Mirror(reflecting: result.counts).children.compactMap(\.label).sorted(),
                       ["booked", "logged", "notLogged", "other", "toDo"],
                       "a week counts the days it booked and the days it holds, and nothing else")

        let banned = ["score", "percent", "rate", "ratio", "average", "total", "streak",
                      "grade", "adherence", "compliance", "best", "record"]
        func walk(_ value: Any, at path: String) {
            let mirror = Mirror(reflecting: value)
            if let text = value as? String {
                XCTAssertFalse(text.contains("%"), "\(path) carries a percentage")
                return
            }
            for child in mirror.children {
                if let label = child.label, !label.hasPrefix(".") {
                    for word in banned {
                        XCTAssertFalse(label.lowercased().contains(word),
                                       "\(path).\(label) reads as a grade")
                    }
                }
                walk(child.value, at: "\(path).\(child.label ?? "_")")
            }
        }
        walk(result, at: "result")
        for line in PlanAndLog.lines(result) {
            XCTAssertFalse(line.contains("%"), "a percentage reached a screen: \(line)")
        }
    }

    func testNothingInThisFeatureCarriesFromOneWeekToTheNext() throws {
        // compare() is handed one week and reads one week: its own window is
        // the only stretch of the log it ever touches.
        var bookings = weekTraining()
        bookings.append(booked("2026-10-05", "Lower A",
                               [lift("Back Squat", "Barbell", [set(225, 5)])]))
        let result = try XCTUnwrap(run(bookings, weekWorkouts()))
        XCTAssertEqual(result.counts.booked, 3)
        XCTAssertTrue(result.days.allSatisfy { $0.key >= mon && $0.key <= sun })
    }

    func testTheFooterIsThisCardsOwnNotTheOneWrittenForACoach() {
        XCTAssertEqual(PlanAndLog.footer,
                       "Your coach’s plan beside your own log. What else the week "
                       + "held, only you know.")
        // Neither of Coach's two third-party sentences can reach this screen,
        // in any state the card has: one is about a link somebody else
        // received, the other about a window somebody else chose to send.
        let every = PlanAndLog.lines(everyState()).joined(separator: " · ")
        XCTAssertFalse(every.contains("opened it, only they know"),
                       "Coach’s footer is a sentence about somebody else")
        XCTAssertFalse(every.contains("outside the log they sent"),
                       "the log is right here; the state cannot arise")
        XCTAssertFalse(PlanAndLog.words.values.contains("outside the log they sent"))
    }

    func testTheWordsACoachReadsAndTheWordsALifterReadsAreTheSameWords() {
        // The four verdicts, taken from Coach web's plan-log.js unchanged --
        // so describing a week to each other does not mean translating it
        // first. `to do` is the one this side adds, because only the person
        // living the week has a day that has not happened yet.
        XCTAssertEqual(PlanAndLog.words, [.logged: "logged", .toDo: "to do",
                                          .notLogged: "not logged", .notBooked: "not booked"])
    }

    // MARK: - Reading the store

    /// The point of the correction the web work made: the ask is the **stored
    /// plan**, not the sets a started session copied in. Editing a logged set
    /// must not quietly rewrite what the coach asked for.
    @MainActor
    func testTheAskComesFromTheStoredPlanAndNotFromTheEditedLog() throws {
        let context = ModelContext(LiftStore.makeContainer(inMemory: true))
        let suite = "plan-and-log-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let routine = Routine(name: "Lower A")
        let exercise = RoutineExercise(name: "Back Squat", equipment: "Barbell", orderIndex: 0)
        exercise.prescribedSets = [
            RoutinePrescribedSet(orderIndex: 0, targetWeightKg: 100, targetReps: 5),
            RoutinePrescribedSet(orderIndex: 1, targetWeightKg: 100, targetReps: 5),
        ]
        routine.exercises = [exercise]
        context.insert(routine)
        let date = try XCTUnwrap(DayKey.date(from: mon))
        context.insert(ScheduledSession(routineID: routine.id, routineName: routine.name,
                                       scheduledFor: date))
        try context.save()

        let logged = routine.startSession(on: date, in: context, defaults: defaults)
        // A hard day: the second set came in light, and one set never happened.
        let entry = try XCTUnwrap(logged.orderedExercises.first)
        if let dropped = entry.orderedSets.last { context.delete(dropped) }
        entry.orderedSets.first?.reps = 3
        try context.save()

        let result = PlanAndLog.compare(
            anchor: mon, today: today,
            sessions: try context.fetch(FetchDescriptor<ScheduledSession>()),
            routines: try context.fetch(FetchDescriptor<Routine>()),
            days: try context.fetch(FetchDescriptor<WorkoutDay>()),
            sides: PlanSides.load(from: defaults), unit: .kilograms, locale: locale)

        let row = try XCTUnwrap(result?.days.first?.exercises.first)
        XCTAssertEqual(row.asked?.text, "100 x 5 · 100 x 5",
                       "the coach's own numbers, not the ones the lifter edited")
        XCTAssertEqual(row.logged?.text, "100 x 3")
        XCTAssertEqual(row.countLine, "Asked 2 sets · logged 1")
    }

    /// The whole way through, from a link a coach sent to the sentence on the
    /// card: `n` reaches the booking and the booking signs the week.
    @MainActor
    func testAPlanAcceptedFromALinkSignsTheWeekWithTheNameItCarried() throws {
        let context = ModelContext(LiftStore.makeContainer(inMemory: true))
        let suite = "plan-and-log-sent-by-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        func accept(_ name: String, on day: String, workout: String, hash: String) throws {
            let payload = PlanPayload(
                v: 1, t: "plan", l: "a1b2c3d4", n: name, r: nil, m: nil,
                w: [PlanWorkout(n: workout, e: [
                    PlanWorkoutExercise(n: "Back Squat", q: "Barbell", c: nil, s: [[225, 5]])
                ])],
                k: [PlanSession(d: day, x: 0)])
            try PlanImporter.accept(payload, hash: hash, in: context, defaults: defaults)
        }
        try accept("Dana Whitfield", on: mon, workout: "Lower A", hash: "s1")
        try accept("", on: "2026-10-05", workout: "Upper B", hash: "s2")

        func week(_ anchor: String) throws -> String {
            let sessions = try context.fetch(FetchDescriptor<ScheduledSession>())
            let result = try XCTUnwrap(PlanAndLog.compare(
                anchor: anchor, today: today, sessions: sessions,
                routines: try context.fetch(FetchDescriptor<Routine>()),
                days: [], sides: PlanSides.load(from: defaults),
                unit: .kilograms, locale: locale))
            return PlanAndLog.sentBy(result, sessions: sessions)
        }
        XCTAssertEqual(try week(mon), "From Dana Whitfield")
        XCTAssertEqual(try week("2026-10-05"), PlanAndLog.noCoachName,
                       "a plan that named nobody signs nothing")
    }

    /// A booking written before the name was kept -- every row in a store
    /// migrated to V9 -- reads exactly as it read then.
    @MainActor
    func testABookingWithNoNameSignsTheWeekAsItAlwaysDid() throws {
        let context = ModelContext(LiftStore.makeContainer(inMemory: true))
        let routine = Routine(name: "Lower A")
        context.insert(routine)
        context.insert(ScheduledSession(routineID: routine.id, routineName: routine.name,
                                        scheduledFor: try XCTUnwrap(DayKey.date(from: mon))))
        try context.save()

        let sessions = try context.fetch(FetchDescriptor<ScheduledSession>())
        XCTAssertNil(sessions.first?.coachName)
        let result = try XCTUnwrap(PlanAndLog.compare(
            anchor: mon, today: today, sessions: sessions,
            routines: try context.fetch(FetchDescriptor<Routine>()), days: [],
            sides: PlanSides(), unit: .kilograms, locale: locale))
        XCTAssertEqual(PlanAndLog.sentBy(result, sessions: sessions), "From your coach")
    }

    /// The sides of the ask come from `PlanSides`, keyed by the routine's own
    /// ids, so an each-side plan reads "L 0/3 · R 0/3" off the stored plan and
    /// not off whatever has been logged against it.
    @MainActor
    func testAnAcceptedPlansSidesAreReadFromTheStoredPlan() throws {
        let context = ModelContext(LiftStore.makeContainer(inMemory: true))
        let suite = "plan-and-log-sides-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let payload = try PlanLinkCodec.decode(
            fragment: PlanSidesDegradationTests.fixtureFragment(),
            expectedLifterID: "a1b2c3d4")
        try PlanImporter.accept(payload, hash: PlanImporter.hash(of: payload), in: context,
                                defaults: defaults)

        // The fixture is a plan link; whether it books a day is not this
        // test's subject, so the routine is booked here on a day of our own.
        let routine = try XCTUnwrap(try context.fetch(FetchDescriptor<Routine>()).first)
        context.insert(ScheduledSession(routineID: routine.id, routineName: routine.name,
                                        scheduledFor: try XCTUnwrap(DayKey.date(from: mon))))
        try context.save()

        let sessions = try context.fetch(FetchDescriptor<ScheduledSession>())
        let sides = PlanSides.load(from: defaults)
        let bookings = PlanAndLog.bookings(
            sessions: sessions, routines: try context.fetch(FetchDescriptor<Routine>()),
            sides: sides)
        XCTAssertTrue(bookings.contains { $0.exercises.contains { $0.eachSide } },
                      "the fixture's each-side exercise arrives as each side")
        XCTAssertTrue(bookings.contains { $0.exercises.contains {
            $0.sets.contains { $0.side != nil } } },
                      "and its named side arrives as a side")

        // Nothing logged yet, and the day is behind us: the card says the day
        // was not logged and does not recite a week of noughts.
        let result = PlanAndLog.compare(bookings: bookings, logged: [], today: tue,
                                        anchor: mon, unit: .kilograms, locale: locale)
        XCTAssertEqual(result?.days.first?.state, .notLogged)
        XCTAssertTrue(PlanAndLog.lines(result).allSatisfy { !$0.contains("0/") })
    }

    /// A booking left over from a store written before `RoutineRemoval` swept
    /// them still draws its day and its own recorded name, with no lifts under
    /// it -- never a crash, and never a day claiming to book nothing.
    @MainActor
    func testABookingWhoseRoutineIsGoneStillDrawsItsDay() throws {
        let bookings = PlanAndLog.bookings(
            sessions: [ScheduledSession(routineID: UUID(), routineName: "Lower A",
                                        scheduledFor: try XCTUnwrap(DayKey.date(from: mon)))],
            routines: [], sides: PlanSides())
        let result = run(bookings, [])
        XCTAssertEqual(result?.days.first?.text, "Mon 12 Oct · Lower A · not logged")
        XCTAssertEqual(result?.days.first?.exercises, [])
    }
}
