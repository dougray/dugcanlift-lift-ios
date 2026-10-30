import XCTest
import SwiftData
import LiftCore
@testable import Lift

/// Set types on the lifter's side (PLAN-FORMAT.md "Set types"): supersets and
/// circuits, drop sets and rest-pause -- read off a coach's plan link, kept
/// beside the routine, carried onto a started day, and trained there.
///
/// `Fixtures/web-plan-set-types.txt` is the link Coach web's own encoder wrote
/// (dugcanlift-coach, `coach/fixtures/`, the same bytes). It is the only thing
/// here that proves interoperability rather than agreement with itself: never
/// regenerate it from Swift. The group rules are Coach web's
/// `prescriptions.js`, and their cases are ported from `set-types.test.mjs`.
final class SetTypesTests: XCTestCase {

    private let lifterID = "a1b2c3d4"
    private var suite = ""
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suite = "set-types-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    private func context() -> ModelContext {
        ModelContext(LiftStore.makeContainer(inMemory: true))
    }

    private func kg(_ lb: Double) -> Double { WeightUnit.pounds.toKilograms(lb) }

    static func fixtureLink(_ name: String = "web-plan-set-types") throws -> String {
        let url = try XCTUnwrap(Bundle(for: SetTypesTests.self).url(forResource: name, withExtension: "txt"),
                                "\(name).txt missing from the test bundle")
        return try String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func fragment(of link: String) throws -> String {
        String(link[link.index(after: try XCTUnwrap(link.firstIndex(of: "#")))...])
    }

    /// The fixture through LIFT's real doors: the intake every door asks, then
    /// the one accept a view uses.
    private func incoming(_ name: String = "web-plan-set-types") throws -> PlanLinkIntake.IncomingPlan {
        let outcome = PlanLinkIntake.read("From Doug: " + (try Self.fixtureLink(name)),
                                          expectedLifterID: lifterID)
        guard case .plan(let plan) = outcome else {
            XCTFail("\(name) should open, got \(outcome)")
            throw CancellationError()
        }
        return plan
    }

    private func acceptFixture(in context: ModelContext) throws -> Routine {
        let plan = try incoming()
        try PlanImporter.accept(plan, hash: PlanImporter.hash(of: plan), in: context, defaults: defaults)
        return try XCTUnwrap(try context.fetch(FetchDescriptor<Routine>()).first)
    }

    // MARK: - The fixture

    func testTheFixtureIsCoachWebsAndCarriesGAsSent() throws {
        let link = try Self.fixtureLink()
        XCTAssertTrue(link.hasPrefix("https://www.dugcanlift.com/lift/#1z"))
        let json = try XCTUnwrap(RoadPickLink.payloadJSON(inFragment: try Self.fragment(of: link)))
        XCTAssertTrue(String(decoding: json, as: UTF8.self).hasPrefix(#"{"v":1,"t":"plan","l":"a1b2c3d4""#),
                      "v stays 1, and the key order is Coach web's, not a Swift encoder's")
        XCTAssertEqual(try incoming().exerciseGroups, [[nil, 1, 1, 2, 2, 2, nil, nil, nil]])
    }

    func testTheFixtureAcceptsWithItsGroupsKindsAndSides() throws {
        let routine = try acceptFixture(in: context())
        let types = RoutineSetTypes.load(from: defaults)
        let sides = PlanSides.load(from: defaults)
        let e = routine.orderedExercises

        XCTAssertEqual(e.map(\.name), [
            "Back Squat", "Dumbbell Bench Press", "Seated Cable Rows",
            "Kettlebell Swing", "Push-Up", "Plank",
            "Triceps Pushdown", "Barbell Curl", "Single-Arm Dumbbell Row"])
        XCTAssertEqual(types.storedGroups(e), [nil, 1, 1, 2, 2, 2, nil, nil, nil])
        XCTAssertEqual(types.labels(e).map { $0?.text }, [
            nil, "Superset A · A1", "Superset A · A2",
            "Circuit B · B1", "Circuit B · B2", "Circuit B · B3",
            nil, nil, nil])
        XCTAssertEqual(e.map { types.kinds(of: $0) }, [
            [nil, nil, nil], [nil, nil, nil], [nil, nil, nil],
            [nil, nil, nil], [nil, nil, nil], [nil, nil],
            [nil, nil, .drop, .drop], [nil, .restPause], [nil, nil, .drop]])

        // Left *and* drop is flags 10: masked, the side survives the kind.
        let row = e[8]
        XCTAssertTrue(sides.isEachSide(row))
        XCTAssertEqual(row.orderedSets.map { sides.side(of: $0) }, [nil, nil, .left])
        XCTAssertEqual(row.orderedSets.map(\.targetWeightKg), [kg(50), kg(50), kg(30)])
        XCTAssertEqual(row.orderedSets.map(\.targetReps), [10, 10, 12])

        // The numbers are the coach's, in kilograms, whatever the flags say.
        XCTAssertEqual(e[6].orderedSets.map(\.targetWeightKg), [kg(70), kg(70), kg(50), kg(35)])
        XCTAssertEqual(e[7].orderedSets.map(\.targetReps), [8, 4])
        XCTAssertEqual(e[5].orderedSets.map(\.targetDurationSec), [45, 45], "a circuit member with fewer sets")
        XCTAssertEqual(ExerciseGrouping.summary(types.storedGroups(e)), "Superset A · Circuit B")
    }

    /// PLAN-FORMAT's promise to a build that knows none of this: ignoring `g`
    /// and bits 3-4, the exercises, the sets and the numbers are unchanged,
    /// and a side masked from bits 1-2 is still right.
    func testAnOldDecoderReadsTheRightExercisesSetsNumbersAndSides() throws {
        let payload = try PlanLinkCodec.decode(fragment: try Self.fragment(of: try Self.fixtureLink()),
                                               expectedLifterID: lifterID)
        XCTAssertEqual(payload.v, 1)
        let workout = try XCTUnwrap(payload.w?.first)
        XCTAssertEqual(workout.e.map(\.n).count, 9)
        XCTAssertEqual(workout.e.map(\.s.count), [3, 3, 3, 3, 3, 2, 4, 2, 3])
        // The five numbers of every tuple, as written.
        XCTAssertEqual(workout.e[6].s.map { Array($0.prefix(2)) }, [[70, 12], [70, 12], [50, 10], [35, 10]])
        XCTAssertEqual(workout.e[7].s.map { Array($0.prefix(2)) }, [[65, 8], [65, 4]])
        XCTAssertEqual(workout.e[8].s.map { Array($0.prefix(2)) }, [[50, 10], [50, 10], [30, 12]])
        // The side read the way every LIFT iOS build since sides reads it.
        XCTAssertEqual(workout.e[8].s.map(PlanSetFlags.sideBits), [nil, nil, 1], "left, though it is 10")
        XCTAssertEqual(workout.e[6].s.map(PlanSetFlags.sideBits), [nil, nil, nil, nil], "8 is no side")
        XCTAssertEqual(workout.e[7].s.map(PlanSetFlags.sideBits), [nil, nil], "16 is no side")
        XCTAssertTrue(workout.e[8].isEachSide)
    }

    // MARK: - Plans without set types

    func testPlansWithoutSetTypesImportExactlyAsBefore() throws {
        for name in ["web-plan-per-side", "web-plan-road-picks"] {
            let plan = try incoming(name)
            XCTAssertEqual(plan.exerciseGroups, [], name)
            XCTAssertEqual(try PlanImporter.hash(of: plan),
                           try PlanImporter.hash(of: plan.payload, roadPickIDs: plan.roadPickIDs),
                           "no groups, no key in the hash: \(name)")
            try PlanImporter.accept(plan, hash: PlanImporter.hash(of: plan), in: context(), defaults: defaults)
            XCTAssertNil(defaults.data(forKey: RoutineSetTypes.storageKey), "nothing written for \(name)")
        }
    }

    func testGroupsAreInTheHash() throws {
        let plan = try incoming()
        XCTAssertNotEqual(try PlanImporter.hash(of: plan),
                          try PlanImporter.hash(of: plan.payload, roadPickIDs: plan.roadPickIDs),
                          "or a resend that only adds a superset would be refused as already imported")
    }

    // MARK: - Reading `g` and the kind bits

    func testAGThatIsNotAPositiveIntegerIsNotGrouped() {
        let json = #"{"w":[{"e":[{"g":1},{"g":"1"},{"g":1.5},{"g":-1},{"g":0},{"g":true},{"g":null},{},{"g":2}]}]}"#
        XCTAssertEqual(PlanGroupLink.groups(inJSON: Data(json.utf8)),
                       [[1, nil, nil, nil, nil, nil, nil, nil, 2]])
        XCTAssertEqual(PlanGroupLink.groups(inJSON: Data(#"{"w":[{"e":[{"n":"a"}]}]}"#.utf8)), [],
                       "no group anywhere is no groups")
        XCTAssertEqual(PlanGroupLink.groups(inJSON: Data(#"{"w":"x"}"#.utf8)), [])
        for junk in ["", "1z", "1z!!!!", "nonsense"] {
            XCTAssertEqual(PlanGroupLink.groups(inFragment: junk), [], junk)
        }
    }

    func testKindsAreMaskedNeverCompared() {
        func kind(_ flags: Double?) -> SetKind? { SetKind(planTuple: [60, 10, nil, nil, nil, flags]) }
        XCTAssertEqual(kind(8), .drop)
        XCTAssertEqual(kind(10), .drop, "left and drop")
        XCTAssertEqual(kind(12), .drop, "right and drop")
        XCTAssertEqual(kind(16), .restPause)
        XCTAssertEqual(kind(18), .restPause)
        XCTAssertNil(kind(24), "3 in bits 3-4 is never written and reads as straight")
        XCTAssertNil(kind(2))
        XCTAssertNil(kind(1))
        XCTAssertNil(kind(8.5))
        XCTAssertNil(kind(-8))
        XCTAssertNil(kind(nil))
        XCTAssertNil(SetKind(planTuple: [60, 10]))
    }

    func testAFirstSetSayingDropIsAcceptedAsStraight() throws {
        let payload = PlanPayload(v: 1, t: "plan", l: lifterID, n: "Doug", r: nil, m: nil,
                                  w: [PlanWorkout(n: "A", e: [PlanWorkoutExercise(
                                      n: "Curl", q: nil, c: nil,
                                      s: [[30, 10, nil, nil, nil, 8], [30, 10, nil, nil, nil, 8]])])],
                                  k: nil)
        let context = context()
        try PlanImporter.accept(payload, hash: PlanImporter.hash(of: payload), in: context, defaults: defaults)
        let routine = try XCTUnwrap(try context.fetch(FetchDescriptor<Routine>()).first)
        XCTAssertEqual(RoutineSetTypes.load(from: defaults).kinds(of: routine.orderedExercises[0]), [nil, .drop])
    }

    // MARK: - The group rules (Coach web's)

    func testAdjacencyMakesTheGroupNotTheNumber() {
        XCTAssertEqual(ExerciseGrouping.runs([7, 7, 3, 3, 3]), [1, 1, 2, 2, 2])
        XCTAssertEqual(ExerciseGrouping.runs([1, nil, 1]), [nil, nil, nil])
        XCTAssertEqual(ExerciseGrouping.runs([nil, 4]), [nil, nil], "a group of one is none")
        XCTAssertEqual(ExerciseGrouping.runs([2, 2, 2, 2]), [1, 1, 1, 1])
        XCTAssertEqual(ExerciseGrouping.runs([0, 0, -1, -1]), [nil, nil, nil, nil])
    }

    func testSupersetWithNextJoinsAndAgainMakesACircuit() {
        var g: [Int?] = [nil, nil, nil, nil]
        g = ExerciseGrouping.settingGroupedWithNext(g, at: 1, true)
        XCTAssertEqual(g, [nil, 1, 1, nil])
        g = ExerciseGrouping.settingGroupedWithNext(g, at: 0, true)
        XCTAssertEqual(g, [1, 1, 1, nil], "joining onto a superset makes a circuit of three")
        XCTAssertEqual(ExerciseGrouping.labels(g).map { $0?.group }, ["Circuit A", "Circuit A", "Circuit A", nil])
    }

    func testJoiningTwoGroupsMakesOne() {
        XCTAssertEqual(ExerciseGrouping.settingGroupedWithNext([1, 1, 2, 2], at: 1, true), [1, 1, 1, 1])
    }

    func testSplittingKeepsWhatIsBeforeTheSplit() {
        XCTAssertEqual(ExerciseGrouping.settingGroupedWithNext([1, 1, 1], at: 0, false), [nil, 1, 1],
                       "split after the first of a circuit: the first is alone, the rest a superset")
        XCTAssertEqual(ExerciseGrouping.settingGroupedWithNext([1, 1, 1], at: 1, false), [1, 1, nil])
        XCTAssertEqual(ExerciseGrouping.settingGroupedWithNext([1, 1], at: 0, false), [nil, nil])
    }

    func testTheLastExerciseHasNoNext() {
        XCTAssertEqual(ExerciseGrouping.settingGroupedWithNext([nil, nil], at: 1, true), [nil, nil])
        XCTAssertFalse(ExerciseGrouping.groupedWithNext([1, 1], at: 1))
        XCTAssertTrue(ExerciseGrouping.groupedWithNext([1, 1], at: 0))
    }

    func testLabelsAndLettersPastZ() {
        XCTAssertEqual(ExerciseGrouping.labels([1, 1, nil, 2, 2]).map { $0?.text },
                       ["Superset A · A1", "Superset A · A2", nil, "Superset B · B1", "Superset B · B2"])
        XCTAssertEqual(ExerciseGrouping.letters(0), "A")
        XCTAssertEqual(ExerciseGrouping.letters(25), "Z")
        XCTAssertEqual(ExerciseGrouping.letters(26), "AA")
        XCTAssertEqual(ExerciseGrouping.letters(27), "AB")
        XCTAssertEqual(ExerciseGrouping.summary([nil, nil]), "")
    }

    // MARK: - The routine's side-car

    func testTheEditorsToggleAndKindMenuWriteTheSideCar() throws {
        let context = context()
        let routine = Routine(name: "Upper")
        routine.exercises = ["Bench", "Row", "Curl"].enumerated().map { i, name in
            let e = RoutineExercise(name: name, orderIndex: i)
            e.prescribedSets = (0..<3).map { RoutinePrescribedSet(orderIndex: $0, targetWeightKg: 20, targetReps: 10) }
            return e
        }
        context.insert(routine)
        try context.save()
        let e = routine.orderedExercises

        var types = RoutineSetTypes()
        types.setGroupedWithNext(true, at: 0, in: e)
        XCTAssertEqual(types.storedGroups(e), [1, 1, nil])
        types.setGroupedWithNext(true, at: 1, in: e)
        XCTAssertEqual(types.storedGroups(e), [1, 1, 1])
        types.setGroupedWithNext(false, at: 0, in: e)
        XCTAssertEqual(types.storedGroups(e), [nil, 1, 1])

        let curl = e[2]
        types.setKind(.drop, for: curl.orderedSets[0], in: curl)
        XCTAssertFalse(types.showsKinds(curl), "the first set takes no kind")
        types.setKind(.restPause, for: curl.orderedSets[2], in: curl)
        XCTAssertEqual(types.kinds(of: curl), [nil, nil, .restPause])
        XCTAssertTrue(types.showsKinds(curl))
        types.setKind(nil, for: curl.orderedSets[2], in: curl)
        XCTAssertEqual(types.kinds, [:], "straight is no entry, not a word written down")

        types.save(to: defaults)
        XCTAssertEqual(RoutineSetTypes.load(from: defaults), types)
    }

    // MARK: - The line that names them

    /// LIFT Android's `RoutineExercise.summary` ends with "set 3 drop, set 4
    /// rest-pause" (`RoutineSetKindsTest`), and LIFT web's targets line with
    /// the same words. Its numbering is from 1, by position; ", " between.
    func testTheKindedSetsAreNamedByNumberInAndroidsWords() {
        XCTAssertEqual(SetKindLine.text([nil, nil, .drop, .restPause]), "set 3 drop, set 4 rest-pause")
        XCTAssertEqual(SetKindLine.text([nil, .restPause]), "set 2 rest-pause")
        XCTAssertEqual(SetKindLine.text([nil, .drop, nil, .drop, nil]), "set 2 drop, set 4 drop")
    }

    func testNoKindsIsNoLine() {
        XCTAssertNil(SetKindLine.text([]))
        XCTAssertNil(SetKindLine.text([nil, nil, nil]))
        XCTAssertNil(SetKindLine.text([.drop]), "set 1 is always straight, and never named")
        XCTAssertEqual(SetKindLine.text([.drop, .drop]), "set 2 drop")
    }

    func testARoutinesLineReadsItsSideCar() throws {
        let context = context()
        let routine = Routine(name: "Push")
        let bench = RoutineExercise(name: "Bench Press", orderIndex: 0)
        bench.prescribedSets = (0..<4).map { RoutinePrescribedSet(orderIndex: $0, targetWeightKg: 84, targetReps: 8) }
        routine.exercises = [bench]
        context.insert(routine)
        try context.save()

        var types = RoutineSetTypes()
        XCTAssertNil(types.kindsLine(of: bench), "a routine of straight sets has no line")
        types.setKind(.restPause, for: bench.orderedSets[3], in: bench)
        types.setKind(.drop, for: bench.orderedSets[2], in: bench)
        XCTAssertEqual(types.kindsLine(of: bench), "set 3 drop, set 4 rest-pause")
        types.setKind(.drop, for: bench.orderedSets[0], in: bench)
        XCTAssertEqual(types.kindsLine(of: bench), "set 3 drop, set 4 rest-pause", "set 1 takes no kind")
        types.setKind(nil, for: bench.orderedSets[2], in: bench)
        types.setKind(nil, for: bench.orderedSets[3], in: bench)
        XCTAssertNil(types.kindsLine(of: bench))
    }

    func testTheSideCarReadsLeniently() throws {
        XCTAssertEqual(RoutineSetTypes.decode(Data("{}".utf8)), RoutineSetTypes())
        XCTAssertEqual(RoutineSetTypes.decode(Data("junk".utf8)), RoutineSetTypes())
        // A sided prescription stored before set types reads as straight.
        let old = #"{"eachSide":true,"sets":[{"weightKg":20,"reps":8,"side":"left"}]}"#
        let prescription = try JSONDecoder().decode(Prescription.self, from: Data(old.utf8))
        XCTAssertNil(prescription.sets[0].kind)
        XCTAssertEqual(prescription.sets[0].side, .left)
    }

    // MARK: - Starting a routine

    @MainActor
    func testStartingTheFixtureCarriesGroupsAndKindsOntoTheDay() throws {
        let context = context()
        let routine = try acceptFixture(in: context)
        let day = routine.startSession(on: .now, in: context, defaults: defaults)
        let types = RoutineSetTypes.load(from: defaults)
        let logged = day.orderedExercises

        XCTAssertEqual(types.loggedLabels(logged).map { $0?.text }, [
            nil, "Superset A · A1", "Superset A · A2",
            "Circuit B · B1", "Circuit B · B2", "Circuit B · B3",
            nil, nil, nil])
        XCTAssertEqual(logged[6].orderedSets.enumerated().map { types.loggedKind(of: $1, at: $0) },
                       [nil, nil, .drop, .drop])
        XCTAssertEqual(logged[7].orderedSets.enumerated().map { types.loggedKind(of: $1, at: $0) },
                       [nil, .restPause])
        // The each-side row is logged set by set, so its drop rides on the
        // prescription Add set reads.
        XCTAssertEqual(logged[8].orderedSets.count, 0)
        let prescription = try XCTUnwrap(PlanSides.prescription(for: logged[8].id, in: defaults))
        XCTAssertEqual(prescription.sets.map(\.kind), [nil, nil, .drop])
        XCTAssertEqual(prescription.sets.map(\.side), [nil, nil, .left])
        XCTAssertEqual(prescription.setFor(side: .left, after: [.left, .right, .left, .right])?.kind, .drop)
    }

    @MainActor
    func testTwoRoutinesStartedOnOneDayKeepTheirGroupsApart() throws {
        let context = context()
        var types = RoutineSetTypes()
        func superset(_ name: String) -> Routine {
            let routine = Routine(name: name)
            routine.exercises = ["\(name) 1", "\(name) 2"].enumerated().map { i, n in
                let e = RoutineExercise(name: n, orderIndex: i)
                e.prescribedSets = [RoutinePrescribedSet(orderIndex: 0, targetReps: 10)]
                return e
            }
            context.insert(routine)
            types.write([1, 1], to: routine.orderedExercises)
            return routine
        }
        let a = superset("A"), b = superset("B")
        try context.save()
        types.save(to: defaults)

        a.startSession(on: .now, in: context, defaults: defaults)
        let day = b.startSession(on: .now, in: context, defaults: defaults)
        XCTAssertEqual(RoutineSetTypes.load(from: defaults).loggedLabels(day.orderedExercises).map { $0?.text },
                       ["Superset A · A1", "Superset A · A2", "Superset B · B1", "Superset B · B2"],
                       "two supersets side by side, never one circuit of four")
    }

    // MARK: - Deleting a routine

    @MainActor
    func testDeletingARoutineTakesItsGroupsAndKindsButNotTheLoggedCopies() throws {
        let context = context()
        let routine = try acceptFixture(in: context)
        let day = routine.startSession(on: .now, in: context, defaults: defaults)
        XCTAssertTrue(RoutineRemoval.remove(routine, in: context, defaults: defaults))

        let types = RoutineSetTypes.load(from: defaults)
        XCTAssertEqual(types.groups, [:])
        XCTAssertEqual(types.kinds, [:])
        XCTAssertEqual(types.loggedLabels(day.orderedExercises).compactMap { $0?.member },
                       ["A1", "A2", "B1", "B2", "B3"], "a session that happened keeps its rounds")
        XCTAssertFalse(types.loggedKinds.isEmpty)
    }
}

/// The rest after a tick, once the day knows its set types (`SessionRest`).
final class SessionRestTests: XCTestCase {

    private typealias S = SessionRest.SetState

    private func exercise(_ name: String, group: Int? = nil, _ sets: [S]) -> SessionRest.Exercise {
        SessionRest.Exercise(name: name, restName: "\(name) (Gear)", group: group, sets: sets)
    }

    func testAnUngroupedDayRestsAsItAlwaysDid() {
        let first = S(), second = S()
        let day = [exercise("Squat", [first, second])]
        XCTAssertEqual(SessionRest.after(ticking: first.id, in: day, restSeconds: 120),
                       .rest(seconds: 120, before: "Squat (Gear)"))
        XCTAssertEqual(SessionRest.after(ticking: second.id, in: day, restSeconds: 120),
                       .rest(seconds: 120, before: "Squat (Gear)"), "the last set rests too")
    }

    func testRestTurnedOffStartsAndSaysNothing() {
        let a = S(), b = S()
        let day = [exercise("Bench", group: 1, [a]), exercise("Rows", group: 1, [b])]
        XCTAssertEqual(SessionRest.after(ticking: a.id, in: day, restSeconds: nil), .nothing)
        XCTAssertEqual(SessionRest.after(ticking: a.id, in: day, restSeconds: 0), .nothing)
    }

    func testInsideASupersetRoundThereIsNoRestUntilItsLastSet() {
        let a1 = S(), a2 = S(), b1 = S(), b2 = S()
        let day = [exercise("Bench", group: 1, [a1, a2]),
                   exercise("Seated Cable Rows", group: 1, [b1, b2])]
        XCTAssertEqual(SessionRest.after(ticking: a1.id, in: day, restSeconds: 90),
                       .noRest(cue: "Next: Seated Cable Rows"))
        var done = day
        done[0].sets[0].done = true
        XCTAssertEqual(SessionRest.after(ticking: b1.id, in: done, restSeconds: 90),
                       .rest(seconds: 90, before: "Bench (Gear)"), "the round's last starts the full rest")
    }

    func testARoundIsNotOverWhileAnEarlierSetOfItIsUnticked() {
        let a1 = S(), b1 = S(), a2 = S(), b2 = S()
        let day = [exercise("Bench", group: 1, [a1, a2]), exercise("Rows", group: 1, [b1, b2])]
        XCTAssertEqual(SessionRest.after(ticking: b1.id, in: day, restSeconds: 90),
                       .noRest(cue: "Next: Bench"), "ticked out of order, Bench is still to do")
    }

    func testACircuitSkipsAMemberThatHasRunOut() {
        let swing = (0..<3).map { _ in S() }, push = (0..<3).map { _ in S() }, plank = (0..<2).map { _ in S() }
        var day = [exercise("Kettlebell Swing", group: 2, swing),
                   exercise("Push-Up", group: 2, push),
                   exercise("Plank", group: 2, plank)]
        let steps = SessionRest.order(day).map { "\($0.exercise)\($0.set)" }
        XCTAssertEqual(steps, ["00", "10", "20", "01", "11", "21", "02", "12"])
        // Round three: Swing, then Push-Up, which is the round's last.
        for i in 0..<3 { day[i].sets[0].done = true; day[i].sets[1].done = true }
        day[0].sets[2].done = true
        XCTAssertEqual(SessionRest.after(ticking: push[2].id, in: day, restSeconds: 60),
                       .rest(seconds: 60, before: "Push-Up (Gear)"))
        day[1].sets[2].done = false
        XCTAssertEqual(SessionRest.after(ticking: swing[2].id, in: day, restSeconds: 60),
                       .noRest(cue: "Next: Push-Up"))
    }

    func testADropSetNextMeansNoRest() {
        let s = (0..<4).map { i in S(kind: i >= 2 ? .drop : nil) }
        let day = [exercise("Triceps Pushdown", s)]
        XCTAssertEqual(SessionRest.after(ticking: s[0].id, in: day, restSeconds: 90),
                       .rest(seconds: 90, before: "Triceps Pushdown (Gear)"))
        XCTAssertEqual(SessionRest.after(ticking: s[1].id, in: day, restSeconds: 90),
                       .noRest(cue: "Drop set next"))
        XCTAssertEqual(SessionRest.after(ticking: s[2].id, in: day, restSeconds: 90),
                       .noRest(cue: "Drop set next"), "a drop after a drop")
        XCTAssertEqual(SessionRest.after(ticking: s[3].id, in: day, restSeconds: 90),
                       .rest(seconds: 90, before: "Triceps Pushdown (Gear)"))
    }

    func testRestPauseNextIsFifteenSeconds() {
        let first = S(), pause = S(kind: .restPause)
        let day = [exercise("Barbell Curl", [first, pause])]
        XCTAssertEqual(SessionRest.after(ticking: first.id, in: day, restSeconds: 120),
                       .rest(seconds: 15, before: "Barbell Curl (Gear)"))
    }

    func testTheNextSetToDoSkipsOnesAlreadyTicked() {
        let a = S(), b = S(done: true), c = S(kind: .drop)
        let day = [exercise("Pushdown", [a, b, c])]
        XCTAssertEqual(SessionRest.after(ticking: a.id, in: day, restSeconds: 90),
                       .noRest(cue: "Drop set next"))
    }

    func testTheLoggedDayIsReadWithTheFirstSetAlwaysStraight() throws {
        let entry = ExerciseEntry(exerciseRefID: "x", name: "Curl", orderIndex: 0, equipment: "barbell")
        let first = SetEntry(orderIndex: 0), second = SetEntry(orderIndex: 1)
        entry.sets = [first, second]
        second.completedAt = .now
        var types = RoutineSetTypes()
        types.loggedKinds[first.id] = .drop
        types.loggedKinds[second.id] = .restPause
        types.loggedGroups[entry.id] = 3
        let read = SessionRest.exercises([entry], setTypes: types)
        XCTAssertEqual(read, [SessionRest.Exercise(
            name: "Curl", restName: "Curl (Barbell)", group: 3,
            sets: [S(id: first.id, done: false, kind: nil), S(id: second.id, done: true, kind: .restPause)])])
    }
}
