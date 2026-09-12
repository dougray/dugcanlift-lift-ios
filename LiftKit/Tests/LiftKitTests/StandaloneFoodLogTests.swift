import XCTest
@testable import LiftKit

final class StandaloneFoodLogTests: XCTestCase {

    private var defaults: UserDefaults!
    private let suiteName = "StandaloneFoodLogTests"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private func food(_ name: String = "Oats, rolled, dry") -> WatchFood {
        WatchFood(name: name, kcal: 379, protein: 13.2, fat: 6.5, carbs: 67.7, fibre: 10.1)
    }

    private func entry(_ name: String = "Oats, rolled, dry", at date: Date = .now) -> LoggedFood {
        LoggedFood(food: food(name), grams: 50, meal: .breakfast, loggedAt: date)
    }

    func testAppendedEntriesSurviveANewInstance() {
        StandaloneFoodLog(defaults: defaults).append(entry())
        XCTAssertEqual(StandaloneFoodLog(defaults: defaults).entries.count, 1)
    }

    func testEntriesComeBackOldestFirst() {
        let log = StandaloneFoodLog(defaults: defaults)
        let now = Date()
        log.append(entry("Second", at: now))
        log.append(entry("First", at: now.addingTimeInterval(-3600)))
        XCTAssertEqual(log.entries.map(\.food.name), ["First", "Second"])
    }

    func testEntryCountIsCappedDroppingOldestFirst() {
        let log = StandaloneFoodLog(defaults: defaults, maxEntries: 3)
        let now = Date()
        for i in 0..<5 {
            log.append(entry("food\(i)", at: now.addingTimeInterval(Double(i) * 60)))
        }
        XCTAssertEqual(log.entries.map(\.food.name), ["food2", "food3", "food4"])
    }

    func testEntriesOlderThanTheAgeCapAreDropped() {
        let log = StandaloneFoodLog(defaults: defaults, maxAgeDays: 60)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        // Calendar arithmetic, never 86400-second arithmetic: the latter
        // repeats a day across a DST transition.
        let old = calendar.date(byAdding: .day, value: -61, to: .now)!
        let recent = calendar.date(byAdding: .day, value: -59, to: .now)!
        log.append(entry("tooOld", at: old))
        log.append(entry("justInside", at: recent))
        XCTAssertEqual(log.entries.map(\.food.name), ["justInside"])
    }

    func testClearEmptiesTheLog() {
        let log = StandaloneFoodLog(defaults: defaults)
        log.append(entry())
        log.clear()
        XCTAssertTrue(log.entries.isEmpty)
        XCTAssertTrue(StandaloneFoodLog(defaults: defaults).entries.isEmpty)
    }

    func testCorruptStoredDataReadsAsEmptyRatherThanCrashing() {
        defaults.set(Data([0x00, 0x01, 0x02]), forKey: "com.dugcanlift.lift.standaloneFoodLog")
        XCTAssertTrue(StandaloneFoodLog(defaults: defaults).entries.isEmpty)
    }

    func testSkippedCountStartsAtZero() {
        XCTAssertEqual(StandaloneFoodLog(defaults: defaults).skippedCount, 0)
    }

    func testRecordSkippedIncrementsAndSurvivesANewInstance() {
        let log = StandaloneFoodLog(defaults: defaults)
        log.recordSkipped()
        log.recordSkipped()
        XCTAssertEqual(log.skippedCount, 2)
        XCTAssertEqual(StandaloneFoodLog(defaults: defaults).skippedCount, 2)
    }

    func testClearResetsSkippedCountAlongsideEntries() {
        let log = StandaloneFoodLog(defaults: defaults)
        log.append(entry())
        log.recordSkipped()
        log.clear()
        XCTAssertEqual(log.skippedCount, 0)
    }

    func testRemoveOnlyDeletesTheGivenEntriesLeavingLaterAppendsIntact() {
        // Mirrors ExportFoodsView: capture what was encoded, then something
        // else lands in the log before the user confirms clearing. Only the
        // captured entries should go.
        let log = StandaloneFoodLog(defaults: defaults)
        let now = Date()
        log.append(entry("Encoded", at: now))
        let captured = log.entries
        log.append(entry("AppendedAfterEncoding", at: now.addingTimeInterval(60)))

        log.remove(captured)

        XCTAssertEqual(log.entries.map(\.food.name), ["AppendedAfterEncoding"])
    }

    func testRemoveOfEverythingLeavesTheLogEmpty() {
        let log = StandaloneFoodLog(defaults: defaults)
        log.append(entry())
        log.remove(log.entries)
        XCTAssertTrue(log.entries.isEmpty)
    }
}
