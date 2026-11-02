import XCTest
import LiftCore
@testable import Lift

final class ProgressRulesTests: XCTestCase {
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = .current
        c.firstWeekday = 2
        return c
    }()

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
    }

    // MARK: - The year

    func testLevelsAreFixedSteps() {
        XCTAssertEqual([0, 1, 9, 10, 19, 20, 60].map(TrainingYear.level), [0, 1, 1, 2, 2, 3, 3])
    }

    func testTheYearEndsWithThisWeekAndNothingAfterTodayIsARestDay() {
        let today = date(2026, 10, 28) // a Wednesday
        let weeks = TrainingYear.weeks(setsByDay: [DayKey.make(from: today): 12], today: today,
                                       calendar: calendar)
        XCTAssertEqual(weeks.count, 53)
        XCTAssertTrue(weeks.allSatisfy { $0.count == 7 })
        let last = weeks.last!
        XCTAssertEqual(DayKey.make(from: last[0].date), "2026-10-26") // Monday first
        XCTAssertEqual(last[2].level, 2)
        XCTAssertFalse(last[2].isFuture)
        XCTAssertTrue(last[3].isFuture)
        XCTAssertEqual(last[3].level, 0)
    }

    func testTrainingDaysCountTheLast365Only() {
        let today = date(2026, 10, 28)
        let counts = [
            "2026-10-28": 5, "2026-10-01": 20, "2025-10-29": 3, // in
            "2025-10-28": 8,                                     // a year and a day ago
            "2026-10-02": 0,                                     // nothing done
        ]
        XCTAssertEqual(TrainingYear.trainingDays(setsByDay: counts, today: today, calendar: calendar), 3)
    }

    // MARK: - Muscles

    func testSetsGoToTheLoggedMuscleThenTheDatabasesThenUnplaced() {
        let lookup = [
            MuscleWeek.key(name: "Barbell Squat", equipment: "Barbell"): "quadriceps",
            MuscleWeek.key(name: "Face Pull", equipment: nil): "shoulders",
        ]
        let logged = [
            MuscleWeek.Logged(name: "Bench Press", equipment: "Barbell", primaryMuscle: "Chest", workingSets: 4),
            MuscleWeek.Logged(name: "Barbell Squat", equipment: "Barbell", primaryMuscle: nil, workingSets: 4),
            MuscleWeek.Logged(name: "Face Pull", equipment: "Cable", primaryMuscle: nil, workingSets: 3),
            MuscleWeek.Logged(name: "My Own Thing", equipment: nil, primaryMuscle: nil, workingSets: 2),
            MuscleWeek.Logged(name: "Warmup only", equipment: nil, primaryMuscle: "calves", workingSets: 0),
        ]
        let result = MuscleWeek.tally(logged, lookup: lookup,
                                      allMuscles: ["chest", "quadriceps", "shoulders", "calves"])
        XCTAssertEqual(result.trained.map(\.muscle), ["chest", "quadriceps", "shoulders"])
        XCTAssertEqual(result.trained.map(\.sets), [4, 4, 3])
        XCTAssertEqual(result.untrained, ["calves"])
        XCTAssertEqual(result.unplacedSets, 2)
    }

    // MARK: - Body weight

    func testOneWeighInADayTheLastOfIt() {
        let morning = date(2026, 10, 27).addingTimeInterval(-4 * 3600)
        let evening = date(2026, 10, 27).addingTimeInterval(6 * 3600)
        let points = BodyWeightTrend.daily([
            .init(date: evening, weightKg: 81), .init(date: morning, weightKg: 80),
            .init(date: date(2026, 10, 20), weightKg: 82),
        ], calendar: calendar)
        XCTAssertEqual(points.map(\.weightKg), [82, 81])
    }

    func testTheSummarySaysTheChangeAndTheGoal() {
        let points: [BodyWeightTrend.Point] = [
            .init(date: date(2026, 8, 1), weightKg: WeightUnit.pounds.toKilograms(200)),
            .init(date: date(2026, 10, 27), weightKg: WeightUnit.pounds.toKilograms(192.4)),
        ]
        let line = BodyWeightTrend.summary(points, goalKg: WeightUnit.pounds.toKilograms(185), unit: .pounds)!
        XCTAssertTrue(line.hasPrefix("192.4 lb · down 7.6 since "), line)
        XCTAssertTrue(line.hasSuffix(" · 7.4 from your goal of 185"), line)
        XCTAssertNil(BodyWeightTrend.summary([], goalKg: nil, unit: .pounds))
        XCTAssertEqual(BodyWeightTrend.summary([points[1]], goalKg: nil, unit: .kilograms), "87.3 kg")
    }
}
