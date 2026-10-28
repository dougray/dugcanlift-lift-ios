import XCTest
import LiftCore
@testable import Lift

final class PlateMathTests: XCTestCase {

    // MARK: - Which bar

    func testTheBarComesFromTheNameAndTheEquipment() {
        XCTAssertEqual(BarKind.of(name: "Barbell Squat", equipment: "barbell"), .barbell)
        XCTAssertEqual(BarKind.of(name: "Bench Press", equipment: "Barbell"), .barbell)
        XCTAssertEqual(BarKind.of(name: "EZ-Bar Curl", equipment: "e-z curl bar"), .ezBar)
        // The exercise data files some EZ-bar lifts under "barbell".
        XCTAssertEqual(BarKind.of(name: "Close-Grip EZ Bar Curl", equipment: "barbell"), .ezBar)
        // And every Smith machine lift under "machine", or even "barbell".
        XCTAssertEqual(BarKind.of(name: "Smith Machine Squat", equipment: "machine"), .smith)
        XCTAssertEqual(BarKind.of(name: "Smith Incline Shoulder Raise", equipment: "barbell"), .smith)
        XCTAssertEqual(BarKind.of(name: "Trap Bar Deadlift", equipment: nil), .trapBar)
        XCTAssertEqual(BarKind.of(name: "Hex Bar Deadlift", equipment: "other"), .trapBar)
        XCTAssertEqual(BarKind.of(name: "Back squat", equipment: "Smith machine"), .smith)
    }

    func testLiftsWithoutABarGetNoPlates() {
        XCTAssertNil(BarKind.of(name: "Dumbbell Bench Press", equipment: "dumbbell"))
        XCTAssertNil(BarKind.of(name: "Leg Press", equipment: "machine"))
        XCTAssertNil(BarKind.of(name: "Pull-up", equipment: "body only"))
        XCTAssertNil(BarKind.of(name: "Bench Press", equipment: nil))
        // One end in the floor: half the bar is not on anyone's shoulders, and
        // "per side" means nothing.
        XCTAssertNil(BarKind.of(name: "Landmine 180's", equipment: "barbell"))
        XCTAssertNil(BarKind.of(name: "T-Bar Row with Handle", equipment: "barbell"))
        XCTAssertNil(BarKind.of(name: "Bent Over One-Arm Long Bar Row", equipment: "barbell"))
        XCTAssertNil(BarKind.of(name: "Single-Arm Linear Jammer", equipment: "barbell"))
    }

    func testEZBarSpellings() {
        XCTAssertEqual(BarKind.of(name: "EZBar Curl", equipment: "barbell"), .ezBar)
        XCTAssertEqual(BarKind.of(name: "Reverse EZ Curl", equipment: "barbell"), .ezBar)
        // "Blacksmith" is not a Smith machine.
        XCTAssertEqual(BarKind.of(name: "Blacksmith Squat", equipment: "barbell"), .barbell)
    }

    // MARK: - Loading

    private let gymPounds = PlateSetup.standard(for: .pounds)
    private let gymKilos = PlateSetup.standard(for: .kilograms)

    func testAnExactLoadInPounds() {
        let load = PlateMath.load(total: 225, bar: .barbell, setup: gymPounds)
        XCTAssertEqual(load, .plates(perSide: [45, 45], total: 225, shortBy: 0))
        let odd = PlateMath.load(total: 185, bar: .barbell, setup: gymPounds)
        XCTAssertEqual(odd, .plates(perSide: [45, 25], total: 185, shortBy: 0))
        let small = PlateMath.load(total: 140, bar: .barbell, setup: gymPounds)
        XCTAssertEqual(small, .plates(perSide: [45, 2.5], total: 140, shortBy: 0))
    }

    func testAnExactLoadInKilograms() {
        let load = PlateMath.load(total: 102.5, bar: .barbell, setup: gymKilos)
        XCTAssertEqual(load, .plates(perSide: [25, 15, 1.25], total: 102.5, shortBy: 0))
    }

    /// Fewest plates, then heavier plates first: 70 a side is 45 + 25, and
    /// 35 + 35 only when there are no 25s.
    func testFewestPlatesWins() {
        let load = PlateMath.load(total: 185, bar: .barbell, setup: gymPounds)
        XCTAssertEqual(load.perSide.count, 2)
        var noTwentyFives = gymPounds
        noTwentyFives.set(pairs: 0, of: 25)
        XCTAssertEqual(PlateMath.load(total: 185, bar: .barbell, setup: noTwentyFives),
                       .plates(perSide: [35, 35], total: 185, shortBy: 0))
    }

    /// A home gym with one pair of 45s and one of 25s cannot make 225. The
    /// answer is the heaviest load at or under the target, and how far short.
    func testWhatYouOwnLimitsTheLoad() {
        var home = PlateSetup.standard(for: .pounds)
        for plate in home.plates { home.set(pairs: 0, of: plate.weight) }
        home.set(pairs: 1, of: 45)
        home.set(pairs: 1, of: 25)
        XCTAssertEqual(PlateMath.load(total: 225, bar: .barbell, setup: home),
                       .plates(perSide: [45, 25], total: 185, shortBy: 40))
    }

    /// Greedy takes the 45 and then cannot make 15 out of 10s it does not own.
    func testItIsNotGreedy() {
        var setup = PlateSetup.standard(for: .pounds)
        for plate in setup.plates { setup.set(pairs: 0, of: plate.weight) }
        setup.set(pairs: 1, of: 45)
        setup.set(pairs: 2, of: 30)
        XCTAssertEqual(PlateMath.load(total: 165, bar: .barbell, setup: setup),
                       .plates(perSide: [30, 30], total: 165, shortBy: 0))
    }

    func testAWeightThatNeedsHalfAPlateIsRoundedDownAndSaysSo() {
        XCTAssertEqual(PlateMath.load(total: 227, bar: .barbell, setup: gymPounds),
                       .plates(perSide: [45, 45], total: 225, shortBy: 2))
    }

    /// Heavier than the bar by less than the smallest plate owned: the bar,
    /// and how far short it is, never "just the bar" as if that were the set.
    func testLessThanTheSmallestPlateOverTheBar() {
        let load = PlateMath.load(total: 47.5, bar: .barbell, setup: gymPounds)
        XCTAssertEqual(load, .plates(perSide: [], total: 45, shortBy: 2.5))
        XCTAssertEqual(load.line(unit: .pounds), "Your plates make 45 lb, 2.5 short. Just the bar")
    }

    func testAnAbsurdWeightIsBoundedByTheRack() {
        let load = PlateMath.load(total: 100_000_000, bar: .barbell, setup: gymPounds)
        guard case let .plates(perSide, total, shortBy) = load else { return XCTFail("\(load)") }
        XCTAssertEqual(perSide.count, 60)
        XCTAssertEqual(total, 45 + 2 * 1225)
        XCTAssertGreaterThan(shortBy, 0)
    }

    func testTheBarAloneAndLessThanTheBar() {
        XCTAssertEqual(PlateMath.load(total: 45, bar: .barbell, setup: gymPounds), .justTheBar)
        XCTAssertEqual(PlateMath.load(total: 30, bar: .barbell, setup: gymPounds), .lighterThanTheBar)
        XCTAssertEqual(PlateMath.load(total: 0, bar: .barbell, setup: gymPounds), .nothing)
    }

    func testEachBarHasItsOwnWeight() {
        XCTAssertEqual(PlateMath.load(total: 75, bar: .ezBar, setup: gymPounds),
                       .plates(perSide: [25], total: 75, shortBy: 0))
        var setup = gymPounds
        setup.setBar(.trapBar, weight: 60)
        XCTAssertEqual(PlateMath.load(total: 150, bar: .trapBar, setup: setup),
                       .plates(perSide: [45], total: 150, shortBy: 0))
    }

    /// Stored kilograms come back to pounds as 224.99999; that is 225.
    func testAConvertedWeightIsNotShortByAHair() {
        let total = WeightUnit.pounds.fromKilograms(WeightUnit.pounds.toKilograms(225))
        XCTAssertEqual(PlateMath.load(total: total, bar: .barbell, setup: gymPounds),
                       .plates(perSide: [45, 45], total: 225, shortBy: 0))
    }

    // MARK: - Words

    func testTheLine() {
        XCTAssertEqual(PlateMath.Load.plates(perSide: [45, 25, 2.5], total: 190, shortBy: 0)
                        .line(unit: .pounds), "Per side: 45 · 25 · 2.5")
        XCTAssertEqual(PlateMath.Load.plates(perSide: [45, 25], total: 185, shortBy: 40)
                        .line(unit: .pounds),
                       "Your plates make 185 lb, 40 short. Per side: 45 · 25")
        XCTAssertEqual(PlateMath.Load.justTheBar.line(unit: .pounds), "Just the bar")
        XCTAssertEqual(PlateMath.Load.lighterThanTheBar.line(unit: .kilograms),
                       "Lighter than the bar")
        XCTAssertNil(PlateMath.Load.nothing.line(unit: .pounds))
    }

    // MARK: - Setup

    func testTheStandardRacks() {
        XCTAssertEqual(gymPounds.plates.map(\.weight), [45, 35, 25, 10, 5, 2.5, 1.25])
        XCTAssertEqual(gymKilos.plates.map(\.weight), [25, 20, 15, 10, 5, 2.5, 1.25, 0.5])
        XCTAssertEqual(gymPounds.barWeight(.barbell), 45)
        XCTAssertEqual(gymKilos.barWeight(.barbell), 20)
        // Fractional plates are not in most gyms; they are there to be added.
        XCTAssertEqual(gymPounds.pairs(of: 1.25), 0)
        XCTAssertEqual(gymKilos.pairs(of: 0.5), 0)
    }

    func testASetupIsKeptPerUnit() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        addTeardownBlock { defaults.removePersistentDomain(forName: #function) }

        XCTAssertEqual(PlateSetup.load(for: .pounds, from: defaults), gymPounds)
        var mine = gymPounds
        mine.set(pairs: 2, of: 45)
        mine.setBar(.barbell, weight: 35)
        mine.save(for: .pounds, to: defaults)
        XCTAssertEqual(PlateSetup.load(for: .pounds, from: defaults), mine)
        XCTAssertEqual(PlateSetup.load(for: .kilograms, from: defaults), gymKilos)
    }

    func testAnUnreadableSetupIsTheStandardOne() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        addTeardownBlock { defaults.removePersistentDomain(forName: #function) }
        defaults.set(Data("nonsense".utf8), forKey: PlateSetup.key(for: .pounds))
        XCTAssertEqual(PlateSetup.load(for: .pounds, from: defaults), gymPounds)
    }
}
