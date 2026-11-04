import XCTest
import LiftSync
@testable import LiftKit

/// The window rule against `Fixtures/heart-rate-per-set.json`, a fixture
/// worked by hand from the build plan's item 16 and checked into this repo
/// and `dugcanlift-lift-watch`, whose Kotlin port reads the same file. It is
/// never regenerated from either port: a fixture the code wrote proves only
/// that the code agrees with itself.
final class SetHeartRateTests: XCTestCase {

    private struct Fixture: Decodable {
        struct Case: Decodable {
            struct Set: Decodable {
                var id: String
                var tick: Double?
                var durationSec: Int?
            }
            var name: String
            var sessionStart: Double
            var samples: [[Double]]
            var sets: [Set]
            var expected: [String: Int?]
        }
        var rule: [String]
        var cases: [Case]
    }

    private func fixture() throws -> Fixture {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "heart-rate-per-set",
                                                  withExtension: "json"))
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    private func date(_ seconds: Double) -> Date { Date(timeIntervalSince1970: seconds) }

    func testEveryCaseInTheSharedFixture() throws {
        let fixture = try fixture()
        XCTAssertFalse(fixture.cases.isEmpty)
        for testCase in fixture.cases {
            let figures = SetHeartRate.figures(
                sessionStart: date(testCase.sessionStart),
                samples: testCase.samples.map { HeartRateSample(date: date($0[0]), bpm: $0[1]) },
                sets: testCase.sets.map {
                    SetHeartRate.Tick(id: $0.id, tick: $0.tick.map(date), durationSec: $0.durationSec)
                }
            )
            // Every set the case names, including the ones expected to have
            // no figure: absent from the result is the rule's nil.
            XCTAssertEqual(Set(testCase.expected.keys), Set(testCase.sets.map(\.id)), testCase.name)
            for (id, expected) in testCase.expected {
                XCTAssertEqual(figures[id], expected, "\(testCase.name): \(id)")
            }
        }
    }

    func testTheFixtureStatesTheRuleThisPortFollows() throws {
        // The rule lines are the contract the two ports share. If one is
        // rewritten, this port has to be read against it again.
        let rule = try fixture().rule.joined(separator: " ")
        XCTAssertTrue(rule.contains("tick + 20"))
        XCTAssertTrue(rule.contains("lookback is 300, or durationSec + 30"))
        XCTAssertTrue(rule.contains("Both ends are inclusive."))
        XCTAssertTrue(rule.contains("halves away from zero"))
        XCTAssertEqual(SetHeartRate.afterTick, 20)
        XCTAssertEqual(SetHeartRate.lookback, 300)
        XCTAssertEqual(SetHeartRate.durationAllowance, 30)
    }

    // MARK: - On the draft

    private func draft(ticks: [Double], start: Double = 0) -> WorkoutDraft {
        var draft = WorkoutDraft(name: "Push", now: date(start))
        let exercise = draft.addExercise(refID: "bench", name: "Bench Press", now: date(start))
        for tick in ticks {
            let id = draft.appendSet(to: exercise, weightKg: 60, reps: 5, now: date(tick))!
            draft.completeSet(id, at: date(tick))
        }
        return draft
    }

    func testAWindowStillOpenGetsNoFigureUntilItCloses() {
        let draft = draft(ticks: [60])
        let samples = [HeartRateSample(date: date(70), bpm: 140)]
        XCTAssertEqual(draft.heartRateUpdates(samples: samples, now: date(79)), [:])
        let set = draft.exercises[0].sets[0].id
        XCTAssertEqual(draft.heartRateUpdates(samples: samples, now: date(80)), [set: 140])
    }

    func testTheNextTickClosesAWindowEarly() {
        let draft = draft(ticks: [60, 70])
        let samples = [HeartRateSample(date: date(65), bpm: 150)]
        let first = draft.exercises[0].sets[0].id
        // 70 is the first set's end, and it has come; the second is open.
        XCTAssertEqual(draft.heartRateUpdates(samples: samples, now: date(71)), [first: 150])
    }

    func testFinishingClosesEveryWindowStillOpen() {
        let draft = draft(ticks: [60])
        let samples = [HeartRateSample(date: date(65), bpm: 150)]
        let set = draft.exercises[0].sets[0].id
        XCTAssertEqual(draft.heartRateUpdates(samples: samples, now: date(66), finishing: true),
                       [set: 150])
    }

    func testAFigureOnlyEverRises() {
        var draft = draft(ticks: [60])
        let set = draft.exercises[0].sets[0].id
        XCTAssertTrue(draft.recordHeartRates([set: 150]))
        // A buffer that has since forgotten the reading finds less, or none.
        XCTAssertEqual(draft.heartRateUpdates(
            samples: [HeartRateSample(date: date(70), bpm: 120)], now: date(400)), [:])
        XCTAssertFalse(draft.recordHeartRates([set: 120]))
        XCTAssertEqual(draft.exercises[0].sets[0].maxBpm, 150)
        // A reading that arrived late raises it.
        XCTAssertEqual(draft.heartRateUpdates(
            samples: [HeartRateSample(date: date(79), bpm: 155)], now: date(400)), [set: 155])
    }

    func testAFigureIsNotARevision() {
        // A reading, not the lifter's edit: no `WORKOUT_EDITED` per window.
        var draft = draft(ticks: [60])
        let revision = draft.revision
        draft.recordHeartRates([draft.exercises[0].sets[0].id: 150])
        XCTAssertEqual(draft.revision, revision)
    }

    func testZeroIsNeverWritten() {
        var draft = draft(ticks: [60])
        XCTAssertFalse(draft.recordHeartRates([draft.exercises[0].sets[0].id: 0]))
        XCTAssertNil(draft.exercises[0].sets[0].maxBpm)
    }

    func testAFinishedDraftTakesNoMoreFigures() {
        // The session that was sent is the session that is kept.
        var draft = draft(ticks: [60])
        draft.finish(at: date(100))
        XCTAssertFalse(draft.recordHeartRates([draft.exercises[0].sets[0].id: 150]))
    }

    func testCorrectingASetKeepsItsFigure() {
        var draft = draft(ticks: [60])
        let set = draft.exercises[0].sets[0].id
        draft.recordHeartRates([set: 150])
        draft.updateSet(set, weightKg: 62.5, reps: 6)
        XCTAssertEqual(draft.set(set)?.maxBpm, 150)
    }

    func testAFigureTravelsInTheFinishedSession() {
        var draft = draft(ticks: [60, 180])
        draft.recordHeartRates([draft.exercises[0].sets[0].id: 150])
        let sets = draft.finishedSession().exercises[0].sets
        XCTAssertEqual(sets.map(\.maxBpm), [150, nil])
    }

    func testADraftWrittenBeforeFiguresDecodesWithNone() throws {
        let json = #"{"id":"6A2A8B6E-3D2F-4E77-9B4E-2C6A5E8C1D01","orderIndex":0,"weightKg":60,"reps":5,"isWarmup":false}"#
        let set = try JSONDecoder().decode(DraftSet.self, from: Data(json.utf8))
        XCTAssertNil(set.maxBpm)
    }

    // MARK: - The words

    /// Shown, never graded: a number and its unit, and no word that judges
    /// it, ranks it, or says what to do about it. The check
    /// `PlanAndLogTests.testNothingInThisCardTellsALifterWhatToDo` makes on
    /// the week card, with the words a heart rate would be graded in.
    func testNothingInTheseLinesTellsALifterWhatToDo() {
        let lines = [
            HeartRateWords.set(maxBpm: 142),
            HeartRateWords.set(maxBpm: 201),
            HeartRateWords.session(SessionHeartRate(averageBpm: 118, maxBpm: 156)),
            HeartRateWords.session(SessionHeartRate(averageBpm: 64, maxBpm: 88))
        ].joined(separator: " · ").lowercased()
        let forbidden = ["zone", "recover", "ready", "rest", "%", "percent", "of max",
                         "target", "threshold", "high", "low", "too ", "should", "warning",
                         "good", "great", "easy", "hard", "effort", "intensity", "fat burn",
                         "cardio", "peak", "aerobic", "anaerobic", "fitness", "trend",
                         "better", "worse", "up ", "down", "↑", "↓"]
        for word in forbidden {
            XCTAssertFalse(lines.contains(word), "\"\(word)\" reached a screen: \(lines)")
        }
    }

    func testTheWordsAreTheOnesEveryBuildSays() {
        XCTAssertEqual(HeartRateWords.set(maxBpm: 142), "max 142 bpm")
        XCTAssertEqual(HeartRateWords.session(SessionHeartRate(averageBpm: 117.5, maxBpm: 156.2)),
                       "Heart rate: average 118 · max 156 bpm")
    }
}
