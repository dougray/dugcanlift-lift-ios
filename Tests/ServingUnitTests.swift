import XCTest
@testable import Lift

final class ServingUnitTests: XCTestCase {
    func testOuncesRoundTrip() {
        let unit = ServingUnit.ounces
        XCTAssertEqual(unit.toGrams(unit.fromGrams(28.3495)), 28.3495, accuracy: 0.001)
    }

    func testGramsIsIdentity() {
        let unit = ServingUnit.grams
        XCTAssertEqual(unit.fromGrams(140), 140, accuracy: 0.0001)
        XCTAssertEqual(unit.toGrams(140), 140, accuracy: 0.0001)
    }

    func testOuncesConversionFactor() {
        // 1 ounce = 28.3495 grams, by definition.
        XCTAssertEqual(ServingUnit.ounces.fromGrams(28.3495), 1.0, accuracy: 0.0001)
    }
}
