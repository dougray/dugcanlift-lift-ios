import XCTest
@testable import Lift

/// The screen stays on while someone is training, and never because of a
/// session they forgot to end.
final class LiveSessionScreenTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testALiveSessionHoldsTheScreenOn() {
        XCTAssertTrue(LiveSessionScreen.holdsScreenOn(
            liveSince: [now.addingTimeInterval(-40 * 60)], enabled: true, now: now))
    }

    func testNoLiveSessionLetsItSleep() {
        XCTAssertFalse(LiveSessionScreen.holdsScreenOn(liveSince: [], enabled: true, now: now))
    }

    func testTheSettingTurnsItOff() {
        XCTAssertFalse(LiveSessionScreen.holdsScreenOn(
            liveSince: [now.addingTimeInterval(-60)], enabled: false, now: now))
    }

    /// A session left running overnight must not keep a phone awake on the
    /// nightstand. Eight hours is as long as iOS keeps a Live Activity.
    func testASessionLeftRunningStopsHoldingAfterEightHours() {
        XCTAssertTrue(LiveSessionScreen.holdsScreenOn(
            liveSince: [now.addingTimeInterval(-(8 * 3600 - 1))], enabled: true, now: now))
        XCTAssertFalse(LiveSessionScreen.holdsScreenOn(
            liveSince: [now.addingTimeInterval(-8 * 3600)], enabled: true, now: now))
    }

    /// Past midnight the session belongs to yesterday's day, and is still on.
    func testASessionThatCrossesMidnightStillHolds() {
        let start = Calendar.current.startOfDay(for: now).addingTimeInterval(-20 * 60)
        let later = Calendar.current.startOfDay(for: now).addingTimeInterval(30 * 60)
        XCTAssertTrue(LiveSessionScreen.holdsScreenOn(liveSince: [start], enabled: true, now: later))
    }

    func testOneRecentSessionAmongStaleOnesHolds() {
        XCTAssertTrue(LiveSessionScreen.holdsScreenOn(
            liveSince: [now.addingTimeInterval(-3 * 86_400), now.addingTimeInterval(-600)],
            enabled: true, now: now))
    }

    func testItIsOnUnlessSomeoneTurnsItOff() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        addTeardownBlock { defaults.removePersistentDomain(forName: #function) }
        XCTAssertTrue(LiveSessionScreen.isEnabled(in: defaults))
        defaults.set(false, forKey: LiveSessionScreen.enabledKey)
        XCTAssertFalse(LiveSessionScreen.isEnabled(in: defaults))
    }
}
