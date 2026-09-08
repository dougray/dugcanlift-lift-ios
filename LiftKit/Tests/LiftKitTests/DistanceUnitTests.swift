import XCTest
@testable import LiftKit

/// Ported from `lift-ios`'s `Sources/Shared/DistanceUnit.swift` (I2 in the
/// final-review fix wave) — a handful of cases mirroring the shape of
/// `WeightUnit`'s own coverage, not a full re-derivation of the math.
final class DistanceUnitTests: XCTestCase {

    func testKilometersRoundTripsThroughMeters() {
        let meters = DistanceUnit.kilometers.toMeters(5)
        XCTAssertEqual(meters, 5000, accuracy: 0.0001)
        XCTAssertEqual(DistanceUnit.kilometers.fromMeters(meters), 5, accuracy: 0.0001)
    }

    func testMilesRoundTripsThroughMeters() {
        let meters = DistanceUnit.miles.toMeters(5)
        XCTAssertEqual(meters, 5 * 1609.344, accuracy: 0.0001)
        XCTAssertEqual(DistanceUnit.miles.fromMeters(meters), 5, accuracy: 0.0001)
    }

    func testAbbreviations() {
        XCTAssertEqual(DistanceUnit.kilometers.abbreviation, "km")
        XCTAssertEqual(DistanceUnit.miles.abbreviation, "mi")
    }
}
