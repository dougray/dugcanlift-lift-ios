import XCTest
@testable import Lift

@MainActor
final class RestTimerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - The countdown

    func testACountdownCountsDown() {
        let rest = RestCountdown(seconds: 90, setID: nil, exerciseName: "Bench Press", now: now)
        XCTAssertEqual(rest.remaining(at: now), 90)
        XCTAssertEqual(rest.remaining(at: now.addingTimeInterval(30)), 60)
        XCTAssertFalse(rest.isOver(at: now.addingTimeInterval(89)))
        XCTAssertTrue(rest.isOver(at: now.addingTimeInterval(90)))
        XCTAssertEqual(rest.remaining(at: now.addingTimeInterval(200)), 0)
    }

    func testFifteenSecondsMoreOrLess() {
        let rest = RestCountdown(seconds: 90, setID: nil, exerciseName: nil, now: now)
        let later = now.addingTimeInterval(30)
        XCTAssertEqual(rest.adjusted(by: 15, now: later).remaining(at: later), 75)
        XCTAssertEqual(rest.adjusted(by: -15, now: later).remaining(at: later), 45)
        // The start stays where it was, so the Live Activity's bar is honest.
        XCTAssertEqual(rest.adjusted(by: 15, now: later).startedAt, now)
    }

    func testTakingTimeOffCannotGoBelowNothing() {
        let rest = RestCountdown(seconds: 30, setID: nil, exerciseName: nil, now: now)
        let later = now.addingTimeInterval(20)
        let shorter = rest.adjusted(by: -15, now: later)
        XCTAssertEqual(shorter.remaining(at: later), 0)
        XCTAssertTrue(shorter.isOver(at: later))
    }

    func testARestIsNeverLongerThanFifteenMinutes() {
        var rest = RestCountdown(seconds: 300, setID: nil, exerciseName: nil, now: now)
        for _ in 0..<100 { rest = rest.adjusted(by: 15, now: now) }
        XCTAssertEqual(rest.remaining(at: now), RestCountdown.longest)
    }

    func testAddingToAnOverRestStartsFromNow() {
        let rest = RestCountdown(seconds: 60, setID: nil, exerciseName: nil, now: now)
        let late = now.addingTimeInterval(100)
        XCTAssertEqual(rest.adjusted(by: 15, now: late).remaining(at: late), 15)
    }

    func testTheClock() {
        XCTAssertEqual(RestCountdown.clock(95), "1:35")
        XCTAssertEqual(RestCountdown.clock(9), "0:09")
        XCTAssertEqual(RestCountdown.clock(0), "0:00")
        // Rounded up, so it never shows 0:00 while there is still time left.
        XCTAssertEqual(RestCountdown.clock(0.2), "0:01")
    }

    // MARK: - The timer

    private final class Outlets: RestOutlets {
        var events: [String] = []
        func restStarted(_ rest: RestCountdown) { events.append("start \(Int(rest.remaining(at: rest.startedAt)))") }
        func restChanged(_ rest: RestCountdown) { events.append("change \(Int(rest.endsAt.timeIntervalSince(rest.startedAt)))") }
        func restCleared() { events.append("clear") }
        func sessionEnded() { events.append("session ended") }
    }

    private func timer(_ outlets: Outlets, function: String = #function) -> RestTimer {
        let defaults = UserDefaults(suiteName: function)!
        defaults.removePersistentDomain(forName: function)
        addTeardownBlock { defaults.removePersistentDomain(forName: function) }
        return RestTimer(outlets: outlets, defaults: defaults)
    }

    func testTickingASetStartsTheRestFromSettings() {
        let outlets = Outlets()
        let timer = timer(outlets)
        let set = UUID()
        timer.setDone(set, exerciseName: "Squat", restSeconds: 120, now: now)
        XCTAssertEqual(timer.current?.setID, set)
        XCTAssertEqual(timer.current?.remaining(at: now), 120)
        XCTAssertEqual(outlets.events, ["start 120"])
    }

    /// The watch's "no rest" setting: a stored non-positive value is nil.
    func testNoRestTimeMeansNoRest() {
        let outlets = Outlets()
        let timer = timer(outlets)
        timer.setDone(UUID(), exerciseName: nil, restSeconds: nil, now: now)
        XCTAssertNil(timer.current)
        XCTAssertEqual(outlets.events, [])
    }

    /// A second set ticked mid-rest starts a fresh rest; the old one is not
    /// left counting behind it.
    func testTheNextSetRestartsTheRest() {
        let outlets = Outlets()
        let timer = timer(outlets)
        timer.setDone(UUID(), exerciseName: "Squat", restSeconds: 90, now: now)
        let second = UUID()
        timer.setDone(second, exerciseName: "Squat", restSeconds: 90, now: now.addingTimeInterval(40))
        XCTAssertEqual(timer.current?.setID, second)
        XCTAssertEqual(timer.current?.remaining(at: now.addingTimeInterval(40)), 90)
        XCTAssertEqual(outlets.events, ["start 90", "start 90"])
    }

    /// Unticking the set a rest belongs to takes the rest back too; unticking
    /// another one leaves it alone.
    func testUntickingTheSetCancelsItsRest() {
        let outlets = Outlets()
        let timer = timer(outlets)
        let set = UUID()
        timer.setDone(set, exerciseName: nil, restSeconds: 90, now: now)
        timer.setUndone(UUID())
        XCTAssertNotNil(timer.current)
        timer.setUndone(set)
        XCTAssertNil(timer.current)
        XCTAssertEqual(outlets.events, ["start 90", "clear"])
    }

    func testAdjustAndSkip() {
        let outlets = Outlets()
        let timer = timer(outlets)
        timer.setDone(UUID(), exerciseName: nil, restSeconds: 90, now: now)
        timer.adjust(by: 15, now: now)
        XCTAssertEqual(timer.current?.remaining(at: now), 105)
        timer.skip()
        XCTAssertNil(timer.current)
        XCTAssertEqual(outlets.events, ["start 90", "change 105", "clear"])
        // Nothing to adjust or skip says nothing.
        timer.adjust(by: 15, now: now)
        timer.skip()
        XCTAssertEqual(outlets.events, ["start 90", "change 105", "clear"])
    }

    /// iOS can end LIFT mid-rest. Coming back, a rest still running is still
    /// on screen; one that ended a while ago is not.
    func testARestSurvivesARelaunchUntilItIsLongOver() {
        let suite = #function
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }

        let first = RestTimer(outlets: Outlets(), defaults: defaults)
        first.setDone(UUID(), exerciseName: "Row", restSeconds: 90, now: now)

        let relaunched = RestTimer(outlets: Outlets(), defaults: defaults)
        relaunched.restore(now: now.addingTimeInterval(30))
        XCTAssertEqual(relaunched.current?.exerciseName, "Row")

        let outlets = Outlets()
        let muchLater = RestTimer(outlets: outlets, defaults: defaults)
        muchLater.restore(now: now.addingTimeInterval(90 + RestTimer.keepsOverFor + 1))
        XCTAssertNil(muchLater.current)
        XCTAssertEqual(outlets.events, ["clear"])
    }

    func testEndingTheSessionEndsTheRest() {
        let outlets = Outlets()
        let timer = timer(outlets)
        timer.setDone(UUID(), exerciseName: nil, restSeconds: 60, now: now)
        timer.sessionEnded()
        XCTAssertNil(timer.current)
        XCTAssertEqual(outlets.events, ["start 60", "clear", "session ended"])
    }

    // MARK: - Set types (`SessionRest`)

    /// Inside a superset round, a tick starts no rest and ends the one still
    /// running: the next set has begun. The banner says what it is instead.
    func testATickWithNoRestEndsTheRunningRestAndSaysWhatIsNext() {
        let outlets = Outlets()
        let timer = timer(outlets)
        timer.setDone(UUID(), exerciseName: "Bench", restSeconds: 90, now: now)
        let a1 = UUID()
        timer.setDone(a1, after: .noRest(cue: "Next: Seated Cable Rows"), exerciseName: "Bench", now: now)
        XCTAssertNil(timer.current)
        XCTAssertEqual(timer.cue, RestTimer.Cue(setID: a1, text: "Next: Seated Cable Rows"))
        XCTAssertEqual(outlets.events, ["start 90", "clear"])

        // The round's last tick starts the full rest, and the cue goes.
        let b1 = UUID()
        timer.setDone(b1, after: .rest(seconds: 90, before: "Bench (Dumbbell)"), exerciseName: "Rows", now: now)
        XCTAssertNil(timer.cue)
        XCTAssertEqual(timer.current?.exerciseName, "Bench (Dumbbell)")
        XCTAssertEqual(outlets.events, ["start 90", "clear", "start 90"])
    }

    func testUntickingTheSetTakesItsCueBackAndDoneDismissesOne() {
        let outlets = Outlets()
        let timer = timer(outlets)
        let set = UUID()
        timer.setDone(set, noRest: "Drop set next")
        timer.setUndone(UUID())
        XCTAssertNotNil(timer.cue)
        timer.setUndone(set)
        XCTAssertNil(timer.cue)
        timer.setDone(set, noRest: "Drop set next")
        timer.skip()
        XCTAssertNil(timer.cue)
        XCTAssertEqual(outlets.events, [], "a cue is not a rest: nothing on the lock screen")
    }

    func testRestPauseIsAFifteenSecondRest() {
        let outlets = Outlets()
        let timer = timer(outlets)
        timer.setDone(UUID(), after: .rest(seconds: SessionRest.restPauseSeconds, before: nil),
                      exerciseName: "Barbell Curl", now: now)
        XCTAssertEqual(timer.current?.remaining(at: now), 15)
        XCTAssertEqual(timer.current?.exerciseName, "Barbell Curl")
        timer.setDone(UUID(), after: .nothing, exerciseName: "Barbell Curl", now: now)
        XCTAssertEqual(outlets.events, ["start 15"], "rest turned off starts nothing, as before")
    }

    func testEndingTheSessionTakesTheCueToo() {
        let timer = timer(Outlets())
        timer.setDone(UUID(), noRest: "Next: Rows")
        timer.sessionEnded()
        XCTAssertNil(timer.cue)
    }

    /// With no rest running, ending the session still clears the lock screen:
    /// an activity can outlive the run of LIFT that started it.
    func testEndingTheSessionWithNoRestStillTellsTheOutlets() {
        let outlets = Outlets()
        let timer = timer(outlets)
        timer.sessionEnded()
        XCTAssertEqual(outlets.events, ["session ended"])
    }
}
