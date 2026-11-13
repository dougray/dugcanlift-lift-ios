import Foundation
import XCTest
@testable import Lift

// The one line a run shows for VO2 max: `VO2 max 46.2 · Nov 8`. Tracked and
// shown, never targeted -- so these tests are about spelling and rounding, and
// that a missing estimate is no line at all.

final class VO2MaxTextTests: XCTestCase {

    private let enUS = Locale(identifier: "en_US")

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func day(_ month: Int, _ day: Int, year: Int = 2026) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    private func line(_ value: Double, on date: Date? = nil, locale: Locale? = nil) -> String? {
        VO2MaxText.line(value: value, date: date ?? day(11, 8), locale: locale ?? enUS, calendar: calendar)
    }

    // MARK: - The words

    func testAWholeNumberDropsItsTrailingZero() {
        XCTAssertEqual(line(46.0), "VO2 max 46 · Nov 8")
    }

    func testOneDecimalIsKept() {
        XCTAssertEqual(line(46.24), "VO2 max 46.2 · Nov 8")
        XCTAssertEqual(line(46.2), "VO2 max 46.2 · Nov 8")
    }

    // MARK: - Rounding: half up on the value's shortest decimal string

    func testAHalfRoundsUpOnTheWrittenValue() {
        // 46.35 and 46.45 are not exact in binary, so rounding the binary
        // value can go either way. The value is read as the digits a person
        // would write, and a written 5 rounds up.
        XCTAssertEqual(line(46.25), "VO2 max 46.3 · Nov 8")
        XCTAssertEqual(line(46.35), "VO2 max 46.4 · Nov 8")
        XCTAssertEqual(line(46.45), "VO2 max 46.5 · Nov 8")
        XCTAssertEqual(line(46.24), "VO2 max 46.2 · Nov 8")
    }

    func testRoundingCanCarryIntoTheWholeNumber() {
        XCTAssertEqual(line(46.96), "VO2 max 47 · Nov 8")
        XCTAssertEqual(line(46.95), "VO2 max 47 · Nov 8")
        XCTAssertEqual(line(46.04), "VO2 max 46 · Nov 8")
    }

    // MARK: - Nothing

    func testAnUnusableValueIsNoLineNotAZeroOrADash() {
        XCTAssertNil(line(0))
        XCTAssertNil(line(-3))
        XCTAssertNil(line(.nan))
        XCTAssertNil(line(.infinity))
    }

    // MARK: - The date follows the reader's locale

    func testTheDateIsAbbreviatedMonthThenDayInUS() {
        XCTAssertEqual(line(46, on: day(3, 1)), "VO2 max 46 · Mar 1")
        XCTAssertEqual(line(46, on: day(12, 25)), "VO2 max 46 · Dec 25")
    }

    func testTheDayAndMonthOrderFollowsTheLocale() {
        // Not asserting a foreign string, which can vary across OS versions:
        // only that it is not the US spelling, and that the day (25) and the
        // value are both still there.
        let us = line(46.2, on: day(12, 25), locale: enUS)
        let uk = line(46.2, on: day(12, 25), locale: Locale(identifier: "en_GB"))
        XCTAssertNotNil(uk)
        XCTAssertNotEqual(us, uk)
        XCTAssertTrue(uk!.contains("25"))
        XCTAssertTrue(uk!.hasPrefix("VO2 max 46.2 · "))
        // US reads month first, GB day first.
        let usDate = us!.dropFirst("VO2 max 46.2 · ".count)
        let ukDate = uk!.dropFirst("VO2 max 46.2 · ".count)
        XCTAssertTrue(usDate.hasPrefix("Dec"))
        XCTAssertTrue(ukDate.hasPrefix("25"))
    }

    func testTheDayIsTheCalendarsDayNotUTCs() {
        var tokyo = calendar
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        // 20:00 UTC on Nov 8 is already Nov 9 in Tokyo.
        let instant = calendar.date(from: DateComponents(year: 2026, month: 11, day: 8, hour: 20))!
        XCTAssertEqual(VO2MaxText.line(value: 46, date: instant, locale: enUS, calendar: tokyo),
                       "VO2 max 46 · Nov 9")
        XCTAssertEqual(VO2MaxText.line(value: 46, date: instant, locale: enUS, calendar: calendar),
                       "VO2 max 46 · Nov 8")
    }
}
