import XCTest
@testable import LiftKit

final class RestTimerTests: XCTestCase {

    func testCountsDownFromConfiguredInterval() {
        var timer = RestTimer(interval: 90)
        timer.start(at: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(timer.remaining(at: Date(timeIntervalSince1970: 30)), 60)
    }

    func testClampsAtZeroAndReportsElapsed() {
        var timer = RestTimer(interval: 90)
        timer.start(at: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(timer.remaining(at: Date(timeIntervalSince1970: 200)), 0)
        XCTAssertTrue(timer.hasFinished(at: Date(timeIntervalSince1970: 200)))
    }

    func testIsNotFinishedBeforeItStarts() {
        let timer = RestTimer(interval: 90)
        XCTAssertFalse(timer.hasFinished(at: Date(timeIntervalSince1970: 1_000)))
        XCTAssertNil(timer.remaining(at: Date(timeIntervalSince1970: 1_000)))
    }

    func testFormatsAsMinutesAndSeconds() {
        XCTAssertEqual(RestTimer.format(97), "01:37")
        XCTAssertEqual(RestTimer.format(0), "00:00")
    }
}
