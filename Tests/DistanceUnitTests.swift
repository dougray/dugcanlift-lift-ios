import XCTest
import LiftCore
@testable import Lift

final class DistanceUnitTests: XCTestCase {
    func testMilesRoundTrip() {
        let unit = DistanceUnit.miles
        XCTAssertEqual(unit.toMeters(unit.fromMeters(1609.344)), 1609.344, accuracy: 0.001)
    }

    func testKilometersIsIdentity() {
        let unit = DistanceUnit.kilometers
        XCTAssertEqual(unit.fromMeters(5000), 5.0, accuracy: 0.0001)
        XCTAssertEqual(unit.toMeters(5.0), 5000, accuracy: 0.0001)
    }

    func testMilesConversionFactor() {
        // 1 mile = 1609.344 meters, exactly, by definition.
        XCTAssertEqual(DistanceUnit.miles.fromMeters(1609.344), 1.0, accuracy: 0.0001)
    }
}
