import XCTest
@testable import Lift

/// The rule that decides when Apple Health's permission sheet may appear:
/// once on its own, never again on launch after an answer, and a tap on
/// "Connect" asks only while HealthKit still has something to ask.
final class HealthAuthorizationTests: XCTestCase {

    private typealias H = HealthAuthorization

    // MARK: Automatic (Home's first run)

    func testFirstLaunchAsksOnce() {
        XCTAssertEqual(H.decide(trigger: .automatic, askedFlag: false, status: .shouldRequest), .request)
    }

    func testLaunchAfterAnyAnswerNeverAsks() {
        // "Don't Allow" and "Allow" look the same from here: both leave the
        // flag set and HealthKit's status unnecessary.
        XCTAssertEqual(H.decide(trigger: .automatic, askedFlag: true, status: .unnecessary), .skip)
        XCTAssertEqual(H.decide(trigger: .automatic, askedFlag: true, status: .unknown), .skip)
    }

    func testAnUpdateAddingATypeDoesNotReAskOnLaunch() {
        // New share or read type: HealthKit says shouldRequest again, but the
        // person has answered LIFT before. That ask belongs to a tap.
        XCTAssertEqual(H.decide(trigger: .automatic, askedFlag: true, status: .shouldRequest), .skip)
    }

    func testAnInstallThatAnsweredBeforeTheFlagExistedCountsAsAsked() {
        // No flag yet, but HealthKit has shown the sheet for every type.
        XCTAssertTrue(H.hasAsked(flag: false, status: .unnecessary))
        XCTAssertEqual(H.decide(trigger: .automatic, askedFlag: false, status: .unnecessary), .skip)
    }

    func testUnknownStatusWithNoFlagStillAsksOnFirstRun() {
        XCTAssertEqual(H.decide(trigger: .automatic, askedFlag: false, status: .unknown), .request)
    }

    // MARK: User action ("Connect Apple Health")

    func testConnectAfterTheSheetWillNotReturnOpensSettings() {
        XCTAssertEqual(H.decide(trigger: .userAction, askedFlag: true, status: .unnecessary), .openSettings)
        XCTAssertEqual(H.decide(trigger: .userAction, askedFlag: false, status: .unnecessary), .openSettings)
    }

    func testConnectAsksWhileHealthKitHasSomethingToAsk() {
        XCTAssertEqual(H.decide(trigger: .userAction, askedFlag: false, status: .shouldRequest), .request)
        XCTAssertEqual(H.decide(trigger: .userAction, askedFlag: true, status: .shouldRequest), .request)
    }

    func testConnectWithUnknownStatusFallsBackOnTheFlag() {
        XCTAssertEqual(H.decide(trigger: .userAction, askedFlag: false, status: .unknown), .request)
        XCTAssertEqual(H.decide(trigger: .userAction, askedFlag: true, status: .unknown), .openSettings)
    }
}
