import XCTest
import SwiftData
import LiftCore
@testable import Lift

/// `TrainingFocus` carried nothing but a `displayName` until 2026-09-13 — it
/// was stored, shown as a day's fallback label and sent to a coach, but no
/// part of the UI read it. These pin the behaviour that replaced that, and
/// pin it against Android, which produces the same strings.
final class FocusMetricsTests: XCTestCase {

    private func makeContext() -> ModelContext {
        ModelContext(LiftStore.makeContainer(inMemory: true))
    }

    @discardableResult
    private func day(_ context: ModelContext,
                     focus: TrainingFocus,
                     sets: [SetEntry]) -> WorkoutDay {
        let day = WorkoutDay(date: .now, name: "Push A", focus: focus)
        let exercise = ExerciseEntry(exerciseRefID: "x", name: "Back Squat", orderIndex: 0)
        exercise.sets = sets
        day.exercises = [exercise]
        context.insert(day)
        return day
    }

    /// Built by converting FROM pounds so the round-trip back to pounds is
    /// exact. Hand-rounded kilograms (102.058) come back as 224.9998 and
    /// render as "225.0", which is a fixture artefact, not a formatting bug.
    private func lb(_ pounds: Double) -> Double { WeightUnit.pounds.toKilograms(pounds) }

    /// 225 x 5 and 205 x 8 — 2765 lb of volume.
    private func strengthSets() -> [SetEntry] {
        [SetEntry(orderIndex: 0, weightKg: lb(225), reps: 5),
         SetEntry(orderIndex: 1, weightKg: lb(205), reps: 8)]
    }

    private func conditioningSets() -> [SetEntry] {
        [SetEntry(orderIndex: 0, weightKg: lb(100), reps: 10, durationSec: 120, distanceMeters: 400),
         SetEntry(orderIndex: 1, weightKg: 0, reps: 0, durationSec: 150, distanceMeters: 600)]
    }

    // MARK: - The summary line differs per focus

    func testBodybuildingIsSummarisedByVolume() {
        let context = makeContext()
        let d = day(context, focus: .bodybuilding, sets: strengthSets())
        XCTAssertEqual(d.summary(unit: .pounds), "2 sets - 2765 lb volume")
    }

    func testPowerliftingIsSummarisedByItsTopSet() {
        let context = makeContext()
        let d = day(context, focus: .powerlifting, sets: strengthSets())
        XCTAssertEqual(d.summary(unit: .pounds), "2 sets - top 225 x 5")
    }

    func testBodybuildingAndPowerliftingNoLongerAgree() {
        let context = makeContext()
        let sets = strengthSets()
        let bb = day(context, focus: .bodybuilding, sets: sets)
        let pl = day(context, focus: .powerlifting, sets: strengthSets())
        XCTAssertNotEqual(bb.summary(unit: .pounds), pl.summary(unit: .pounds),
                          "these two produced identical output on every platform before today")
    }

    func testCrossFitIsSummarisedByWorkingTime() {
        let context = makeContext()
        let d = day(context, focus: .crossfit, sets: conditioningSets())
        XCTAssertEqual(d.summary(unit: .pounds), "2 sets - 4:30 working")
    }

    func testHyroxAndEnduranceAreSummarisedByDistanceAndTime() {
        let context = makeContext()
        let hyrox = day(context, focus: .hyrox, sets: conditioningSets())
        let endurance = day(context, focus: .endurance, sets: conditioningSets())
        XCTAssertEqual(hyrox.summary(unit: .pounds), "2 sets - 1.00 km - 4:30")
        XCTAssertEqual(endurance.summary(unit: .pounds), "2 sets - 1.00 km - 4:30")
    }

    func testVolumeIsShownInTheUsersOwnUnit() {
        // The one place iOS deliberately differs from Android and the browser,
        // which are pounds-native and have no unit preference to honour.
        let context = makeContext()
        let d = day(context, focus: .bodybuilding, sets: strengthSets())
        XCTAssertEqual(d.summary(unit: .kilograms), "2 sets - 1254 kg volume")
    }

    // MARK: - A day holding none of the focus's metric

    func testATimedFocusOverAWeightsOnlyDaySaysNothingAboutDistance() {
        let context = makeContext()
        for focus in [TrainingFocus.crossfit, .hyrox, .endurance] {
            let d = day(context, focus: focus, sets: strengthSets())
            XCTAssertEqual(d.summary(unit: .pounds), "2 sets",
                           "\(focus) must not report a zero that was never logged")
        }
    }

    func testAVolumeFocusOverATimedOnlyDayFallsBackToTheCount() {
        let context = makeContext()
        let d = day(context, focus: .bodybuilding,
                    sets: [SetEntry(orderIndex: 0, durationSec: 300)])
        XCTAssertEqual(d.summary(unit: .pounds), "1 set")
    }

    func testWarmupsAreExcludedFromTheTopSetAsWellAsFromVolume() {
        let context = makeContext()
        let d = day(context, focus: .powerlifting, sets: [
            SetEntry(orderIndex: 0, weightKg: lb(315), reps: 3, isWarmup: true),
            SetEntry(orderIndex: 1, weightKg: lb(225), reps: 5)
        ])
        XCTAssertEqual(d.summary(unit: .pounds), "2 sets - top 225 x 5",
                       "a heavy warmup is not the day's top set")
    }

    // MARK: - The roster now agrees with Android and the browser

    func testThereAreSixStylesMatchingTheOtherApps() {
        XCTAssertEqual(TrainingFocus.allCases.map(\.rawValue),
                       ["bodybuilding", "powerlifting", "crossfit", "hyrox", "endurance", "everything"])
    }

    func testDaysWrittenAsConditioningLandOnEndurance() {
        // `conditioning` was this app's own fourth style; no other app had it.
        // A day already on disk that way must still open, as endurance.
        XCTAssertEqual(TrainingFocus.decode("conditioning"), .endurance)
        XCTAssertEqual(TrainingFocus.decode("hyrox"), .hyrox)
        XCTAssertNil(TrainingFocus.decode("nonsense"))
    }

    func testAStoredConditioningDayReadsBackAsEndurance() throws {
        let context = makeContext()
        let d = WorkoutDay(date: .now, name: "Old day", focus: .bodybuilding)
        context.insert(d)
        try context.save()
        d.focusRaw = "conditioning"
        XCTAssertEqual(d.focus, .endurance)
    }

    // MARK: - What a new set starts at

    func testTheRepDefaultIsATrainingDecisionNotAConstant() {
        XCTAssertEqual(TrainingFocus.bodybuilding.defaultReps, 10)
        XCTAssertEqual(TrainingFocus.powerlifting.defaultReps, 5)
        XCTAssertEqual(TrainingFocus.everything.defaultReps, 8)
        XCTAssertNil(TrainingFocus.crossfit.defaultReps)
        XCTAssertNil(TrainingFocus.hyrox.defaultReps)
        XCTAssertNil(TrainingFocus.endurance.defaultReps)
    }

    // MARK: - Labels, matching Android's FocusMetrics.kt

    func testTimeReadsMmSsUntilItPassesAnHour() {
        XCTAssertEqual(SetMetrics.clock(45), "0:45")
        XCTAssertEqual(SetMetrics.clock(270), "4:30")
        XCTAssertEqual(SetMetrics.clock(3600), "1:00:00")
        XCTAssertEqual(SetMetrics.clock(3725), "1:02:05")
    }

    func testDistanceTurnsIntoKmAtAKilometre() {
        XCTAssertEqual(SetMetrics.distance(400), "400 m")
        XCTAssertEqual(SetMetrics.distance(999), "999 m")
        XCTAssertEqual(SetMetrics.distance(1000), "1.00 km")
        XCTAssertEqual(SetMetrics.distance(5200), "5.20 km")
    }

    func testDurationParsingAcceptsWhatPeopleType() {
        XCTAssertEqual(SetMetrics.parseDuration("90"), 90)
        XCTAssertEqual(SetMetrics.parseDuration("1:30"), 90)
        XCTAssertEqual(SetMetrics.parseDuration("1:30:00"), 5400)
        XCTAssertEqual(SetMetrics.parseDuration(" 2:05 "), 125)
    }

    func testAnUntimedSetIsNotAZeroSecondSet() {
        XCTAssertNil(SetMetrics.parseDuration(""))
        XCTAssertNil(SetMetrics.parseDuration("abc"))
        XCTAssertNil(SetMetrics.parseDuration("1:2:3:4"))
    }

    // MARK: - The set row still shows what the editor stops asking for

    func testASetKeepsAndShowsEveryFieldRegardlessOfFocus() {
        let set = SetEntry(orderIndex: 0, weightKg: WeightUnit.pounds.toKilograms(100), reps: 10,
                           durationSec: 120, distanceMeters: 400)
        XCTAssertEqual(set.display(unit: .pounds), "100 x 10 2:00 400 m")
    }

    func testASetWithOnlyATimeDoesNotRenderAsZeroByZero() {
        let set = SetEntry(orderIndex: 0, durationSec: 120)
        XCTAssertEqual(set.display(unit: .pounds), "2:00")
    }
}

/// The wire format reserved positions 4 and 5 for seconds and metres while this
/// app had no way to record either, and hard-coded them null. Now that schema
/// V6 gives a set both, they must actually be sent — otherwise a coach loses
/// every interval and sled push an iPhone client logs while seeing the Android
/// ones.
final class CoachShareSetMetricsTests: XCTestCase {

    func testATimedAndMeasuredSetPutsBothOnTheWire() {
        let set = SetEntry(orderIndex: 0, weightKg: WeightUnit.pounds.toKilograms(100),
                           reps: 1, durationSec: 90, distanceMeters: 25)
        let tuple = CoachShare.setTuple(set)

        XCTAssertEqual(tuple.count, 5, "[weight, reps, rpe, seconds, metres] — flags 0 is trimmed")
        XCTAssertEqual(tuple[3] as? Int, 90, "position 4 is seconds")
        XCTAssertEqual(tuple[4] as? Double, 25, "position 5 is metres")
    }

    func testAnOrdinarySetStillTrimsToThreeValues() {
        // The trailing-blank trim is what keeps a barbell set at eleven
        // characters; filling positions 4 and 5 must not have cost that.
        let set = SetEntry(orderIndex: 0, weightKg: WeightUnit.pounds.toKilograms(225), reps: 5)
        let tuple = CoachShare.setTuple(set)
        XCTAssertEqual(tuple.count, 2, "weight and reps only — rpe onwards are blank")
    }

    func testAWarmupStillFlagsItself() {
        let set = SetEntry(orderIndex: 0, weightKg: WeightUnit.pounds.toKilograms(135),
                           reps: 5, isWarmup: true)
        let tuple = CoachShare.setTuple(set)
        XCTAssertEqual(tuple.count, 6)
        XCTAssertEqual(tuple[5] as? Int, 1)
    }
}
