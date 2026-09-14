import XCTest
import LiftCore
@testable import Lift

/// `SetEntry.display` claims to match Android's `formatSet`. It didn't, for
/// the one shape a ready-made split produces on every single set: reps with
/// no load. Android wrote "6 reps"; this app wrote "0 x 6".
final class SetDisplayParityTests: XCTestCase {

    private func set(weightKg: Double = 0, reps: Int = 0,
                     rpe: Double? = nil, durationSec: Int? = nil,
                     distanceMeters: Double? = nil) -> SetEntry {
        let entry = SetEntry(orderIndex: 0)
        entry.weightKg = weightKg
        entry.reps = reps
        entry.rpe = rpe
        entry.durationSec = durationSec
        entry.distanceMeters = distanceMeters
        return entry
    }

    func testRepsWithNoLoadReadAsRepsNotAZeroNobodyEntered() {
        // Every set in every starter split is this shape.
        XCTAssertEqual(set(reps: 6).display(unit: .pounds), "6 reps")
        XCTAssertEqual(set(reps: 12).display(unit: .kilograms), "12 reps")
    }

    func testAWeightAndRepsStillPair() {
        XCTAssertEqual(set(weightKg: 100, reps: 5).display(unit: .kilograms), "100 x 5")
    }

    func testAWeightWithNoRepsCarriesItsUnitTheWayAndroidDoes() {
        XCTAssertEqual(set(weightKg: 100, reps: 0).display(unit: .kilograms), "100 kg")
        XCTAssertEqual(set(weightKg: 100, reps: 0).display(unit: .pounds), "220.5 lb")
    }

    func testATimedSetIsUnaffected() {
        XCTAssertEqual(set(durationSec: 45).display(unit: .pounds), "0:45")
        XCTAssertEqual(set(reps: 3, durationSec: 45).display(unit: .pounds), "3 reps 0:45")
    }

    func testAnEmptySetIsStillADash() {
        XCTAssertEqual(set().display(unit: .pounds), "-")
    }

    func testRPEAndDistanceStillAppend() {
        XCTAssertEqual(set(weightKg: 100, reps: 5, rpe: 8).display(unit: .kilograms), "100 x 5 @8")
        // 1600 m crosses into kilometres — SetMetrics.distance switches at 1000.
        XCTAssertEqual(set(distanceMeters: 1600).display(unit: .pounds), "1.60 km")
        XCTAssertEqual(set(distanceMeters: 400).display(unit: .pounds), "400 m")
    }
}
