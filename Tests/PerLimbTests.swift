import XCTest
import SwiftData
import LiftCore
@testable import Lift

/// Per-limb sets: the side column, the two wire formats it travels in, the
/// grouping key it joins, and the imbalance maths read off the result.
///
/// The rule under all of it is that **absent is "both"**. Every set stored
/// before this feature has no side, every link and backup written before it
/// has no side in it, and all of them have to keep meaning exactly what they
/// meant.
final class PerLimbTests: XCTestCase {

    private func makeContext() -> ModelContext {
        ModelContext(LiftStore.makeContainer(inMemory: true))
    }

    // MARK: - SHARE-FORMAT: flags bits 1-2

    func testSetTupleCarriesSideInFlagsBitsOneAndTwo() {
        let both = SetEntry(orderIndex: 0, weightKg: 100, reps: 5)
        let left = SetEntry(orderIndex: 1, weightKg: 100, reps: 5, side: .left)
        let right = SetEntry(orderIndex: 2, weightKg: 100, reps: 5, side: .right)

        // Both: flags is 0, and a zero trailing field is trimmed away
        // entirely, so the tuple is the two fields it always was.
        XCTAssertEqual(CoachShare.setTuple(both).count, 2)
        XCTAssertEqual(CoachShare.setTuple(both)[1] as? Int, 5)
        XCTAssertEqual(CoachShare.setTuple(left).last as? Int, 0b010)
        XCTAssertEqual(CoachShare.setTuple(right).last as? Int, 0b100)
    }

    func testWarmupAndSideShareTheByteWithoutColliding() {
        let warmupLeft = SetEntry(orderIndex: 0, weightKg: 60, reps: 5,
                                  isWarmup: true, side: .left)
        let flags = try? XCTUnwrap(CoachShare.setTuple(warmupLeft).last as? Int)
        XCTAssertEqual(flags, 0b011, "bit 0 warmup, bits 1-2 side")
        XCTAssertEqual((flags ?? 0) & 0b1, 1)
        XCTAssertEqual(SetSide.fromShareFlags(flags ?? 0), .left)
    }

    func testSideBitsRoundTripThroughTheFlagsByte() {
        for side in [SetSide.left, .right] {
            for warmup in [false, true] {
                let set = SetEntry(orderIndex: 0, weightKg: 80, reps: 6,
                                   isWarmup: warmup, side: side)
                let flags = (CoachShare.setTuple(set).last as? Int) ?? 0
                XCTAssertEqual(SetSide.fromShareFlags(flags), side)
                XCTAssertEqual(flags & 0b1 == 1, warmup)
            }
        }
    }

    /// An old link has no side bits, so every set in it is "both" — which is
    /// what those sets have always been.
    func testAnOldFormatLinkDecodesAsBoth() {
        XCTAssertNil(SetSide.fromShareFlags(0), "no flags at all")
        XCTAssertNil(SetSide.fromShareFlags(1), "warmup only, as every pre-V8 encoder wrote it")
    }

    /// `3` in bits 1-2 is never written. Reading it as "both" rather than as
    /// a side means a bit added later cannot silently turn a two-sided set
    /// into a left one.
    func testAnUnknownSideBitPatternReadsAsBoth() {
        XCTAssertNil(SetSide.fromShareFlags(0b111))
    }

    /// The whole reason side rides in `flags` instead of a seventh position:
    /// a decoder that has never heard of it still reads the set.
    func testSideBitsDoNotCorruptVolumeForADecoderThatIgnoresThem() {
        let both = SetEntry(orderIndex: 0, weightKg: 100, reps: 5, rpe: 8,
                            durationSec: 45, distanceMeters: 400)
        let left = SetEntry(orderIndex: 0, weightKg: 100, reps: 5, rpe: 8,
                            durationSec: 45, distanceMeters: 400, side: .left)

        let bothTuple = CoachShare.setTuple(both)
        let leftTuple = CoachShare.setTuple(left)

        // The tuple never grows past the six fields it has always had. A side
        // can be the difference between a trimmed trailing zero and a present
        // `flags` — which is the same shape a warmup already produced, and
        // which every decoder already handles, since trailing nulls have
        // always been trimmed.
        XCTAssertEqual(bothTuple.count, 5, "flags 0 trims away, as it always did")
        XCTAssertEqual(leftTuple.count, 6)

        // Positions 0-4 are identical: the weight, the reps, the RPE, the
        // seconds and the metres a coach's week is built from.
        for position in 0..<5 {
            XCTAssertEqual(
                String(describing: bothTuple[position]),
                String(describing: leftTuple[position]),
                "position \(position) must not move or change when a side is recorded")
        }

        // And the volume such a decoder computes is the same number — it
        // masks bit 0 for warmup and never looks at the rest.
        let legacyVolume: ([Any]) -> Double = { tuple in
            let weight = tuple[0] as? Double ?? 0
            let reps = tuple[1] as? Int ?? 0
            let flags = tuple.count > 5 ? (tuple[5] as? Int ?? 0) : 0
            return flags & 0b1 == 1 ? 0 : weight * Double(reps)
        }
        XCTAssertEqual(legacyVolume(bothTuple), legacyVolume(leftTuple))
        XCTAssertGreaterThan(legacyVolume(leftTuple), 0)
    }

    /// A decoder that reads the warmup bit as the whole byte — `flags == 1`
    /// rather than `flags & 1` — would call a right-side working set a
    /// working set anyway, and a left-side one a working set too. Pinned
    /// because the other platforms must mask, not compare.
    func testAWorkingSetWithASideIsNotMistakenForAWarmup() {
        let left = SetEntry(orderIndex: 0, weightKg: 100, reps: 5, side: .left)
        let flags = (CoachShare.setTuple(left).last as? Int) ?? 0
        XCTAssertEqual(flags & 0b1, 0, "bit 0 is clear: this is a working set")
        XCTAssertNotEqual(flags, 1)
    }

    // MARK: - BACKUP-FORMAT: a named field

    func testSidesRoundTripThroughABackup() throws {
        let source = makeContext()
        let day = WorkoutDay(date: .now, name: "Legs")
        source.insert(day)
        let exercise = ExerciseEntry(exerciseRefID: "x", name: "Bulgarian Split Squat",
                                     orderIndex: 0, equipment: "dumbbell")
        exercise.day = day
        source.insert(exercise)
        for (index, side) in [SetSide?.none, .left, .right].enumerated() {
            let set = SetEntry(orderIndex: index, weightKg: 40, reps: 8, side: side)
            set.exercise = exercise
            source.insert(set)
        }
        try source.save()

        let data = try BackupStore.build(context: source)

        // The field is named, in the common shape, and omitted when both.
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let dataBlock = try XCTUnwrap(json["data"] as? [String: Any])
        let workout = try XCTUnwrap((dataBlock["workouts"] as? [[String: Any]])?.first)
        let sets = try XCTUnwrap(((workout["exercises"] as? [[String: Any]])?.first)?["sets"] as? [[String: Any]])
        XCTAssertEqual(sets.count, 3)
        XCTAssertNil(sets[0]["side"], "both is the absence of the key, never \"both\"")
        XCTAssertEqual(sets[1]["side"] as? String, "left")
        XCTAssertEqual(sets[2]["side"] as? String, "right")

        let destination = makeContext()
        XCTAssertTrue(BackupStore.restore(context: destination, from: data).ok)
        let restored = try XCTUnwrap(try destination.fetch(FetchDescriptor<ExerciseEntry>()).first)
        XCTAssertEqual(restored.orderedSets.map(\.side), [nil, .left, .right])
    }

    /// A file written before per-limb logging has no `side` anywhere, and
    /// every set in it must restore as both rather than as left.
    func testABackupWrittenBeforeSidesRestoresAsBoth() throws {
        let source = makeContext()
        let day = WorkoutDay(date: .now, name: "Push")
        source.insert(day)
        let exercise = ExerciseEntry(exerciseRefID: "x", name: "Bench Press",
                                     orderIndex: 0, equipment: "barbell")
        exercise.day = day
        source.insert(exercise)
        let set = SetEntry(orderIndex: 0, weightKg: 100, reps: 5)
        set.exercise = exercise
        source.insert(set)
        try source.save()

        // Strip every `side` key, which is exactly what an older writer
        // produced.
        var json = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: try BackupStore.build(context: source)) as? [String: Any])
        XCTAssertFalse(String(decoding: try JSONSerialization.data(withJSONObject: json),
                              as: UTF8.self).contains("\"side\""),
                       "a two-sided set writes no side key in the first place")

        json["schemaVersion"] = json["schemaVersion"] ?? 1
        let legacy = try JSONSerialization.data(withJSONObject: json)

        let destination = makeContext()
        XCTAssertTrue(BackupStore.restore(context: destination, from: legacy).ok)
        let restored = try XCTUnwrap(try destination.fetch(FetchDescriptor<SetEntry>()).first)
        XCTAssertNil(restored.side)
    }

    func testAnUnknownSideStringRestoresAsBothRatherThanFailing() {
        XCTAssertNil(SetSide.fromBackup("both"))
        XCTAssertNil(SetSide.fromBackup("sideways"))
        XCTAssertNil(SetSide.fromBackup(nil))
        XCTAssertNil(SetSide.fromBackup(1))
        XCTAssertEqual(SetSide.fromBackup("LEFT"), .left)
        XCTAssertEqual(SetSide.fromBackup(" right "), .right)
    }

    // MARK: - Display

    func testASideIsTheLastPartOfASetsDisplay() {
        XCTAssertEqual(
            SetEntry(orderIndex: 0, weightKg: WeightUnit.pounds.toKilograms(185),
                     reps: 5, side: .left)
                .display(unit: .pounds),
            "185 x 5 L")
        XCTAssertEqual(
            SetEntry(orderIndex: 0, weightKg: 100, reps: 5).display(unit: .kilograms),
            "100 x 5",
            "a two-sided set is byte for byte what it always was")
        XCTAssertEqual(
            SetEntry(orderIndex: 0, weightKg: 100, reps: 5, side: .right)
                .display(unit: .kilograms, includingSide: false),
            "100 x 5",
            "the row's own L/R control must not be said twice")
    }

    // MARK: - Grouping

    func testGroupingNeverMergesLeftAndRight() throws {
        let context = makeContext()
        let day = WorkoutDay(date: .now)
        context.insert(day)
        let exercise = ExerciseEntry(exerciseRefID: "x", name: "Single-Arm Row",
                                     orderIndex: 0, equipment: "dumbbell")
        exercise.day = day
        context.insert(exercise)
        for (index, side) in [SetSide.left, .right].enumerated() {
            let set = SetEntry(orderIndex: index, weightKg: 40, reps: 8, side: side)
            set.exercise = exercise
            context.insert(set)
        }
        try context.save()

        let series = LiftProgression.series(
            for: ExerciseKey.make(name: "Single-Arm Row", equipment: "dumbbell"), in: [day])
        XCTAssertEqual(series.map(\.side), [.left, .right])
        XCTAssertEqual(series.count, 2, "two limbs are two series, never one average")

        let keys = LiftProgression.allSeries(in: [day]).keys
        XCTAssertEqual(Set(keys.map(\.side)), [.left, .right])
    }

    func testATwoSidedLiftProducesExactlyOneSeries() throws {
        let context = makeContext()
        let day = WorkoutDay(date: .now)
        context.insert(day)
        let exercise = ExerciseEntry(exerciseRefID: "x", name: "Bench Press",
                                     orderIndex: 0, equipment: "barbell")
        exercise.day = day
        context.insert(exercise)
        for index in 0..<3 {
            let set = SetEntry(orderIndex: index, weightKg: 100, reps: 5)
            set.exercise = exercise
            context.insert(set)
        }
        try context.save()

        let series = LiftProgression.series(
            for: ExerciseKey.make(name: "Bench Press", equipment: "barbell"), in: [day])
        XCTAssertEqual(series.count, 1)
        XCTAssertNil(series.first?.side)
        XCTAssertNil(LiftProgression.imbalance(in: series),
                     "a two-sided lift has no imbalance figure at all")
    }

    func testEquipmentStillSeparatesOtherwiseIdenticalLifts() throws {
        let context = makeContext()
        let day = WorkoutDay(date: .now)
        context.insert(day)
        for (index, equipment) in ["cable", "machine"].enumerated() {
            let exercise = ExerciseEntry(exerciseRefID: "x\(index)", name: "Lat Pulldown",
                                         orderIndex: index, equipment: equipment)
            exercise.day = day
            context.insert(exercise)
            let set = SetEntry(orderIndex: 0, weightKg: 60, reps: 10)
            set.exercise = exercise
            context.insert(set)
        }
        try context.save()

        XCTAssertEqual(LiftProgression.allSeries(in: [day]).count, 2)
        XCTAssertEqual(
            LiftProgression.series(for: ExerciseKey.make(name: "Lat Pulldown", equipment: "cable"),
                                   in: [day]).count,
            1)
    }

    /// A day's several sets of one side are one point, taking the best.
    func testADaysBestSetIsTheDaysPoint() throws {
        let context = makeContext()
        let day = WorkoutDay(date: .now)
        context.insert(day)
        let exercise = ExerciseEntry(exerciseRefID: "x", name: "Pistol Squat",
                                     orderIndex: 0, equipment: "body only")
        exercise.day = day
        context.insert(exercise)
        for (index, weight) in [40.0, 50.0, 45.0].enumerated() {
            let set = SetEntry(orderIndex: index, weightKg: weight, reps: 5, side: .left)
            set.exercise = exercise
            context.insert(set)
        }
        try context.save()

        let series = LiftProgression.series(
            for: ExerciseKey.make(name: "Pistol Squat", equipment: "body only"), in: [day])
        XCTAssertEqual(series.first?.points.count, 1)
        XCTAssertEqual(series.first?.bestOneRepMaxKg ?? 0,
                       50 * (1 + 5.0 / 30.0), accuracy: 0.0001)
    }

    // MARK: - Imbalance maths
    //
    // The rule is LIFT web's `lift/sides.js`, which LIFT Android matches too:
    // a side's figure is the mean of its LAST THREE sessions, shown only when
    // both sides have three, and the trend compares that against the mean of
    // the FIRST THREE and needs four a side. These numbers are printed to a
    // person about their own body on three platforms; they must be the same
    // number.

    private func points(_ values: [Double], from day: Int = 0) -> [LiftSessionPoint] {
        values.enumerated().map { index, value in
            let date = Calendar.current.date(
                byAdding: .day, value: day + index * 3,
                to: Date(timeIntervalSince1970: 1_700_000_000))!
            return LiftSessionPoint(dayKey: DayKey.make(from: date), date: date,
                                    estimatedOneRepMaxKg: value)
        }
    }

    func testTheFigureIsTheMeanOfEachSidesLastThreeSessions() throws {
        // Left's last three mean 100, right's mean 90 — and left's early
        // 200 is deliberately far enough out to fail a "best day" reading.
        let imbalance = try XCTUnwrap(LiftProgression.imbalance(
            left: points([200, 90, 100, 110]),
            right: points([50, 80, 90, 100])))
        XCTAssertEqual(imbalance.strongerSide, .left)
        XCTAssertEqual(imbalance.percent, 10, accuracy: 0.0001)
        XCTAssertEqual(imbalance.percentText, "10.0%")
    }

    func testAPeakIsNotTheFigure() throws {
        // One heavy day on the left, three years ago in chart terms: the
        // last three are level, so the sides are even.
        let imbalance = try XCTUnwrap(LiftProgression.imbalance(
            left: points([300, 100, 100, 100]),
            right: points([100, 100, 100, 100])))
        XCTAssertEqual(imbalance.percent, 0, accuracy: 0.0001,
                       "a best day forever would read 66% here")
        XCTAssertNil(imbalance.strongerSide, "a dead heat has no stronger side")
    }

    func testAPerfectlyBalancedPairIsZeroAndSteady() throws {
        let imbalance = try XCTUnwrap(LiftProgression.imbalance(
            left: points([90, 95, 100, 100]), right: points([90, 95, 100, 100])))
        XCTAssertEqual(imbalance.percent, 0, accuracy: 0.0001)
        XCTAssertNil(imbalance.strongerSide)
        XCTAssertEqual(imbalance.trend, .steady)
        XCTAssertEqual(imbalance.trendText, "holding steady")
    }

    func testNotEnoughSessionsOnOneSideMeansNoFigureAtAll() {
        XCTAssertNil(LiftProgression.imbalance(
            left: points([90, 95, 100, 105, 110, 115]), right: points([80, 85])),
            "two right-hand days is one bad day away from meaningless")
        XCTAssertNil(LiftProgression.imbalance(left: points([90]), right: points([80])))
        XCTAssertNil(LiftProgression.imbalance(left: [], right: points([80, 85, 90])))
    }

    func testThreeSessionsEachSideIsTheFloorAndItIsInclusive() throws {
        let imbalance = try XCTUnwrap(LiftProgression.imbalance(
            left: points([90, 95, 100]), right: points([80, 85, 90])))
        // Means of 95 and 85.
        XCTAssertEqual(imbalance.percent, (95 - 85) / 95 * 100, accuracy: 0.0001)
    }

    func testThreeSessionsIsNeverEnoughForATrend() throws {
        let imbalance = try XCTUnwrap(LiftProgression.imbalance(
            left: points([90, 95, 100]), right: points([80, 85, 90])))
        XCTAssertEqual(imbalance.trend, .notEnoughData,
                       "the first three and the last three are the same sessions")
        XCTAssertNil(imbalance.trendText)
        XCTAssertNil(imbalance.previousPercent)
    }

    func testAGapThatGrowsIsWidening() throws {
        // First three: left 100 vs right 95, a 5% gap. Last three: 100 vs 85.
        let imbalance = try XCTUnwrap(LiftProgression.imbalance(
            left: points([100, 100, 100, 100, 100, 100]),
            right: points([95, 95, 95, 85, 85, 85])))
        XCTAssertEqual(imbalance.strongerSide, .left)
        XCTAssertEqual(imbalance.previousPercent ?? 0, 5, accuracy: 0.0001)
        XCTAssertEqual(imbalance.percent, 15, accuracy: 0.0001)
        XCTAssertEqual(imbalance.trend, .widening)
        XCTAssertEqual(imbalance.trendText, "widening")
    }

    func testAGapThatShrinksIsClosing() throws {
        let imbalance = try XCTUnwrap(LiftProgression.imbalance(
            left: points([100, 100, 100, 100, 100, 100]),
            right: points([85, 85, 85, 95, 95, 95])))
        XCTAssertEqual(imbalance.previousPercent ?? 0, 15, accuracy: 0.0001)
        XCTAssertEqual(imbalance.percent, 5, accuracy: 0.0001)
        XCTAssertEqual(imbalance.trend, .closing)
    }

    /// Half a percentage point of movement is noise in an estimate built out
    /// of an estimate, and below it the gap has not done anything.
    func testAGapThatBarelyMovesIsSteady() throws {
        let imbalance = try XCTUnwrap(LiftProgression.imbalance(
            left: points([100, 100, 100, 100, 100, 100]),
            right: points([90, 90, 90, 90.2, 90.2, 90.2])))
        XCTAssertEqual(imbalance.trend, .steady)
    }

    /// The sides are read in date order, not in the order they were handed
    /// over — "last three" has to mean last three in time.
    func testSessionsAreOrderedByDateBeforeTheLastThreeAreTaken() throws {
        let ordered = points([50, 100, 100, 100])
        let shuffled = [ordered[3], ordered[0], ordered[2], ordered[1]]
        let straight = try XCTUnwrap(LiftProgression.imbalance(
            left: ordered, right: points([90, 90, 90, 90])))
        let jumbled = try XCTUnwrap(LiftProgression.imbalance(
            left: shuffled, right: points([90, 90, 90, 90])))
        XCTAssertEqual(straight.percent, jumbled.percent, accuracy: 0.0001)
        XCTAssertEqual(straight.percent, 10, accuracy: 0.0001)
    }

    func testTheGapIsAlwaysRelativeToTheStrongerSide() {
        XCTAssertEqual(LiftProgression.gap(100, 90) ?? 0, 10, accuracy: 0.0001)
        XCTAssertEqual(LiftProgression.gap(90, 100) ?? 0, 10, accuracy: 0.0001)
        XCTAssertNil(LiftProgression.gap(0, 0))
    }

    // MARK: - The per-exercise preference

    func testTheNamesGuessIsOnlyADefault() {
        XCTAssertTrue(UnilateralGuess.looksUnilateral(name: "Bulgarian Split Squat"))
        XCTAssertTrue(UnilateralGuess.looksUnilateral(name: "Single-Arm Dumbbell Row"))
        XCTAssertTrue(UnilateralGuess.looksUnilateral(name: "Walking Lunge"))
        XCTAssertTrue(UnilateralGuess.looksUnilateral(name: "Smith Single-Leg Split Squat"))
        XCTAssertFalse(UnilateralGuess.looksUnilateral(name: "Barbell Bench Press"))
        XCTAssertFalse(UnilateralGuess.looksUnilateral(name: "Deadlift"))
    }

    func testTheLiftersOwnAnswerOutranksTheGuessInBothDirections() {
        var raw = "{}"
        // Off by default for a two-sided name, on for a unilateral one.
        XCTAssertFalse(PerSideLogging.effective(name: "Bench Press", equipment: "barbell", in: raw))
        XCTAssertTrue(PerSideLogging.effective(name: "Pistol Squat", equipment: nil, in: raw))

        // A "no" on a name the guess says yes to must stick.
        raw = PerSideLogging.setting(false,
                                     for: ExerciseKey.make(name: "Pistol Squat", equipment: nil),
                                     in: raw)
        XCTAssertFalse(PerSideLogging.effective(name: "Pistol Squat", equipment: nil, in: raw))

        // And a "yes" on one it says no to.
        raw = PerSideLogging.setting(true,
                                     for: ExerciseKey.make(name: "Bench Press", equipment: "barbell"),
                                     in: raw)
        XCTAssertTrue(PerSideLogging.effective(name: "Bench Press", equipment: "barbell", in: raw))
    }

    func testThePreferenceIsKeyedByNameAndEquipment() {
        let raw = PerSideLogging.setting(
            true, for: ExerciseKey.make(name: "Row", equipment: "cable"), in: "{}")
        XCTAssertTrue(PerSideLogging.effective(name: "Row", equipment: "cable", in: raw))
        XCTAssertFalse(PerSideLogging.effective(name: "Row", equipment: "machine", in: raw),
                       "a cable row and a machine row are not the same lift")
        // Capitalisation is a spelling, not an identity.
        XCTAssertTrue(PerSideLogging.effective(name: "ROW", equipment: "Cable", in: raw))
    }

    func testAnUnreadablePreferenceBlobIsEmptyRatherThanFatal() {
        XCTAssertEqual(PerSideLogging.decode("not json"), [:])
        XCTAssertNil(PerSideLogging.isOn("anything", in: ""))
    }

    // MARK: - Alternating

    func testANewSetLandsOnTheSideWithFewerLoggedSoFar() throws {
        let context = makeContext()
        let exercise = ExerciseEntry(exerciseRefID: "x", name: "Step-Up",
                                     orderIndex: 0, equipment: "dumbbell")
        context.insert(exercise)

        XCTAssertEqual(exercise.nextSide, .left, "an empty exercise starts on the left")

        let left = SetEntry(orderIndex: 0, weightKg: 20, reps: 10, side: .left)
        left.exercise = exercise
        context.insert(left)
        XCTAssertEqual(exercise.nextSide, .right)

        let right = SetEntry(orderIndex: 1, weightKg: 20, reps: 10, side: .right)
        right.exercise = exercise
        context.insert(right)
        XCTAssertEqual(exercise.nextSide, .left, "so it alternates without a tap")

        XCTAssertEqual(exercise.perSideCountLabel, "L 1 · R 1")
        XCTAssertEqual(exercise.lastSet(on: .left)?.id, left.id)
    }

    func testTheHeaderCountMakesAMissedSideObvious() throws {
        let context = makeContext()
        let exercise = ExerciseEntry(exerciseRefID: "x", name: "Lunge",
                                     orderIndex: 0, equipment: nil)
        context.insert(exercise)
        for (index, side) in [SetSide.left, .right, .left].enumerated() {
            let set = SetEntry(orderIndex: index, weightKg: 20, reps: 10, side: side)
            set.exercise = exercise
            context.insert(set)
        }
        XCTAssertEqual(exercise.perSideCountLabel, "L 2 · R 1")
    }

    /// Sets logged before the toggle went on are still in the exercise and
    /// still real. LIFT web says so in the same words.
    func testUnmarkedSetsAreCountedAsBothRatherThanQuietlyDropped() throws {
        let context = makeContext()
        let exercise = ExerciseEntry(exerciseRefID: "x", name: "Lunge",
                                     orderIndex: 0, equipment: nil)
        context.insert(exercise)
        for (index, side) in [SetSide?.none, .none, .left].enumerated() {
            let set = SetEntry(orderIndex: index, weightKg: 20, reps: 10, side: side)
            set.exercise = exercise
            context.insert(set)
        }
        XCTAssertEqual(exercise.perSideCountLabel, "L 1 · R 0 · 2 both")
    }

    // MARK: - The schema column

    func testTheSideColumnStoresAndReloads() throws {
        let context = makeContext()
        let set = SetEntry(orderIndex: 0, weightKg: 40, reps: 8, side: .right)
        context.insert(set)
        try context.save()

        let reloaded = try XCTUnwrap(try context.fetch(FetchDescriptor<SetEntry>()).first)
        XCTAssertEqual(reloaded.side, .right)
        XCTAssertEqual(reloaded.sideRaw, "right")

        reloaded.side = nil
        try context.save()
        XCTAssertNil(try context.fetch(FetchDescriptor<SetEntry>()).first?.sideRaw)
    }

    /// A raw string nobody recognises reads as both instead of failing to
    /// open — the same forgiveness `WorkoutDay.focusRaw` has.
    func testAnUnrecognisedRawSideReadsAsBoth() throws {
        let context = makeContext()
        let set = SetEntry(orderIndex: 0, weightKg: 40, reps: 8)
        set.sideRaw = "middle"
        context.insert(set)
        try context.save()
        XCTAssertNil(try context.fetch(FetchDescriptor<SetEntry>()).first?.side)
    }
}
