import XCTest
import SwiftData
@testable import Lift

final class NutritionFactsTests: XCTestCase {

    func testAdditionSumsMacros() {
        let a = NutritionFacts(calories: 100, proteinG: 10, carbsG: 5, fatG: 2)
        let b = NutritionFacts(calories: 250, proteinG: 20, carbsG: 30, fatG: 8)
        let total = a + b

        XCTAssertEqual(total.calories, 350)
        XCTAssertEqual(total.proteinG, 30)
        XCTAssertEqual(total.carbsG, 35)
        XCTAssertEqual(total.fatG, 10)
    }

    func testMissingFibreStaysMissing() {
        let a = NutritionFacts(calories: 100, proteinG: 0, carbsG: 0, fatG: 0)
        let b = NutritionFacts(calories: 100, proteinG: 0, carbsG: 0, fatG: 0)
        XCTAssertNil((a + b).fiberG, "nil + nil must not become 0")
    }

    func testPartialFibreIsPreserved() {
        var a = NutritionFacts(calories: 100, proteinG: 0, carbsG: 0, fatG: 0)
        a.fiberG = 3
        let b = NutritionFacts(calories: 100, proteinG: 0, carbsG: 0, fatG: 0)
        XCTAssertEqual((a + b).fiberG, 3)
    }

    func testScaling() {
        let base = NutritionFacts(calories: 100, proteinG: 10, carbsG: 5, fatG: 2)
        let scaled = base.scaled(by: 1.5)
        XCTAssertEqual(scaled.calories, 150)
        XCTAssertEqual(scaled.proteinG, 15)
    }
}

final class WorkoutMathTests: XCTestCase {

    func testWarmupSetsAreExcludedFromVolume() {
        let working = SetEntry(orderIndex: 0, reps: 10, weightKg: 50)
        let warmup = SetEntry(orderIndex: 1, reps: 10, weightKg: 20, isWarmup: true)

        XCTAssertEqual(working.volumeKg, 500)
        XCTAssertEqual(warmup.volumeKg, 0)
    }

    func testEpleyEstimate() {
        let set = SetEntry(orderIndex: 0, reps: 5, weightKg: 100)
        XCTAssertEqual(set.estimatedOneRepMaxKg ?? 0, 116.67, accuracy: 0.01)
    }

    func testNoEstimateForWarmups() {
        let set = SetEntry(orderIndex: 0, reps: 5, weightKg: 100, isWarmup: true)
        XCTAssertNil(set.estimatedOneRepMaxKg)
    }

    func testUnitConversionRoundTrips() {
        let kg = 102.5
        let lb = WeightUnit.pounds.fromKilograms(kg)
        XCTAssertEqual(WeightUnit.pounds.toKilograms(lb), kg, accuracy: 0.0001)
    }
}

final class DayKeyTests: XCTestCase {

    func testKeyIsStableAcrossTimeZones() {
        let date = Date(timeIntervalSince1970: 1_754_500_000)
        let austin = DayKey.make(from: date, timeZone: TimeZone(identifier: "America/Chicago")!)
        let tokyo = DayKey.make(from: date, timeZone: TimeZone(identifier: "Asia/Tokyo")!)

        XCTAssertEqual(austin.count, 10)
        XCTAssertNotEqual(austin, tokyo, "A fixed instant falls on different local days")
    }

    func testFormat() {
        let date = Date(timeIntervalSince1970: 0)
        let key = DayKey.make(from: date, timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertEqual(key, "1970-01-01")
    }
}
