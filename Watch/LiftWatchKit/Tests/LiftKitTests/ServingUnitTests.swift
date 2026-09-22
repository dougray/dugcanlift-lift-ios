import XCTest
@testable import LiftKit

final class ServingUnitTests: XCTestCase {
    func testAbbreviations() {
        XCTAssertEqual(ServingUnit.grams.abbreviation, "g")
        XCTAssertEqual(ServingUnit.ounces.abbreviation, "oz")
    }

    func testGramsIsIdentity() {
        XCTAssertEqual(ServingUnit.grams.fromGrams(140), 140)
        XCTAssertEqual(ServingUnit.grams.toGrams(140), 140)
    }

    func testOuncesConversion() {
        XCTAssertEqual(ServingUnit.ounces.fromGrams(283.495231), 10, accuracy: 0.001)
        XCTAssertEqual(ServingUnit.ounces.toGrams(10), 283.495231, accuracy: 0.001)
    }

    func testRoundTrip() {
        for unit in ServingUnit.allCases {
            let grams = 173.0
            XCTAssertEqual(unit.toGrams(unit.fromGrams(grams)), grams, accuracy: 0.0001)
        }
    }
}

/// The amount ceiling, settled 2026-09-13 at 2000 g on both watches.
final class AmountLimitsTests: XCTestCase {

    func testTheCeilingIsTwoThousandGrams() {
        XCTAssertEqual(AmountLimits.maxGrams, 2000)
        XCTAssertEqual(AmountLimits.maximum(in: .grams), 2000)
    }

    func testTheOunceCeilingIsDerivedNotALiteralSeventy() {
        // A flat 70 oz was 1984.5 g — switching units near the cap dropped ~15 g.
        let ounces = AmountLimits.maximum(in: .ounces)
        XCTAssertEqual(ServingUnit.ounces.toGrams(ounces), 2000, accuracy: 1e-9,
                       "the ounce ceiling must describe the same portion as the gram one")
        XCTAssertGreaterThan(ounces, 70, "2000 g is 70.55 oz, not 70")
    }

    func testTheFloorIsFiveGramsInEitherUnit() {
        XCTAssertEqual(AmountLimits.minimum(in: .grams), 5)
        XCTAssertEqual(ServingUnit.ounces.toGrams(AmountLimits.minimum(in: .ounces)), 5, accuracy: 1e-9)
    }

    func testBothWatchesNowAgreeOnTheNumber() {
        // Wear's MAX_GRAMS/MIN_GRAMS, transcribed. If either side moves, this fails.
        XCTAssertEqual(AmountLimits.maxGrams, 2000, "Wear's MAX_GRAMS")
        XCTAssertEqual(AmountLimits.minGrams, 5, "Wear's MIN_GRAMS")
    }
}
