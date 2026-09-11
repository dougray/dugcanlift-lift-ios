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
