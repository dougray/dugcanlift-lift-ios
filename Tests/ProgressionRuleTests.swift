import XCTest
import LiftCore
@testable import Lift

final class ProgressionRuleTests: XCTestCase {
    private let monday = Date(timeIntervalSince1970: 1_800_000_000)
    private let earlier = Date(timeIntervalSince1970: 1_799_500_000)

    private func session(_ weight: Double, _ reps: [Int], on date: Date? = nil) -> ProgressionRule.Session {
        ProgressionRule.Session(date: date ?? monday,
                                sets: reps.map { ProgressionRule.LoggedSet(weight: weight, reps: $0) })
    }

    func testEverySetReachedItsRepsGoesUpAStep() {
        let next = ProgressionRule.next(target: 8, setCount: 3,
                                        sessions: [session(185, [8, 8, 9])], step: 5)
        XCTAssertEqual(next, .up(to: 190, from: 185, reps: 8, date: monday))
    }

    func testOneShortSetMeansTheSameWeightAgain() {
        let next = ProgressionRule.next(target: 8, setCount: 3,
                                        sessions: [session(185, [8, 8, 6])], step: 5)
        XCTAssertEqual(next, .same(185, reps: [8, 8, 6], target: 8, date: monday))
    }

    /// Two sets of eight is not three sets of eight.
    func testFewerSetsThanTheRoutineAsksForIsNotDone() {
        let next = ProgressionRule.next(target: 8, setCount: 3,
                                        sessions: [session(185, [8, 8])], step: 5)
        XCTAssertEqual(next?.weight, 185)
    }

    /// The top weight decides: a lighter back-off set short of the reps does
    /// not hold back a session whose heavy sets all got there.
    func testOnlyTheTopWeightsSetsCount() {
        var last = session(185, [8, 8, 8])
        last.sets.append(.init(weight: 135, reps: 5))
        let next = ProgressionRule.next(target: 8, setCount: 3, sessions: [last], step: 5)
        XCTAssertEqual(next?.weight, 190)
    }

    func testShortTwiceRunningAtTheSameWeightBacksOff() {
        let sessions = [session(185, [8, 7, 6]), session(185, [8, 6, 6], on: earlier)]
        let next = ProgressionRule.next(target: 8, setCount: 3, sessions: sessions, step: 5)
        XCTAssertEqual(next, .backOff(to: 165, from: 185, target: 8))
    }

    /// Short now, but the time before was at a lighter weight: that was the
    /// first try at this one, not a stall.
    func testShortOnceAfterGoingUpIsNotAStall() {
        let sessions = [session(190, [8, 7, 6]), session(185, [8, 8, 8], on: earlier)]
        XCTAssertEqual(ProgressionRule.next(target: 8, setCount: 3, sessions: sessions, step: 5)?.weight, 190)
    }

    func testNothingHonestToSayIsNoSuggestion() {
        XCTAssertNil(ProgressionRule.next(target: 8, setCount: 3, sessions: [], step: 5))
        XCTAssertNil(ProgressionRule.next(target: 0, setCount: 3, sessions: [session(185, [8])], step: 5))
        // Bodyweight: no step to take.
        XCTAssertNil(ProgressionRule.next(target: 8, setCount: 3, sessions: [session(0, [10, 10, 10])], step: 5))
    }

    /// A pound weight stored as kilograms reads back a hair off; the next one
    /// is still a real plate pair.
    func testAConvertedWeightStepsCleanly() {
        let stored = WeightUnit.pounds.fromKilograms(WeightUnit.pounds.toKilograms(185))
        let next = ProgressionRule.next(target: 8, setCount: 1, sessions: [session(stored, [8])], step: 5)
        XCTAssertEqual(next?.weight, 190)
    }

    func testTheStepIsAPairOfTheSmallestPlateOwned() {
        let pounds = PlateSetup.standard(for: .pounds)
        XCTAssertEqual(ProgressionRule.step(unit: .pounds, bar: .barbell, setup: pounds), 5)
        var withChange = pounds
        withChange.set(pairs: 1, of: 1.25)
        XCTAssertEqual(ProgressionRule.step(unit: .pounds, bar: .barbell, setup: withChange), 2.5)
        XCTAssertEqual(ProgressionRule.step(unit: .kilograms, bar: .barbell,
                                            setup: PlateSetup.standard(for: .kilograms)), 2.5)
        // Off the bar the plates do not matter.
        XCTAssertEqual(ProgressionRule.step(unit: .pounds, bar: nil, setup: withChange), 5)
        XCTAssertEqual(ProgressionRule.step(unit: .kilograms, bar: nil, setup: pounds), 2.5)
    }

    func testTheLinesSayWhy() {
        XCTAssertTrue(ProgressionRule.line(.up(to: 190, from: 185, reps: 8, date: monday), unit: .pounds)
            .hasPrefix("Next: 190 lb. Every set reached 8 at 185 last time ("))
        XCTAssertTrue(ProgressionRule.line(.same(185, reps: [8, 8, 6], target: 8, date: monday), unit: .pounds)
            .hasPrefix("Next: 185 lb again. 8, 8, 6 at 185 last time ("))
        XCTAssertEqual(ProgressionRule.line(.backOff(to: 75, from: 82.5, target: 5), unit: .kilograms),
                       "Next: 75 kg. Short of 5 at 82.5 two sessions running, so back off and build up again.")
    }
}
