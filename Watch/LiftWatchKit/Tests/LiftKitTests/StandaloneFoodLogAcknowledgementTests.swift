import XCTest
@testable import LiftKit
import LiftSync

/// A food logged from the phone's recent list goes to the phone *and* into
/// the standalone log. Once the phone has stored it, it must leave the log,
/// or a later QR export puts it into the web app a second time. Until then
/// it must stay, however long delivery takes.
final class StandaloneFoodLogAcknowledgementTests: XCTestCase {

    private var defaults: UserDefaults!
    private let suiteName = "StandaloneFoodLogAcknowledgementTests"

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

    private let oats = WatchFood(name: "Oats, rolled, dry", kcal: 379, protein: 13.2,
                                 fat: 6.5, carbs: 67.7, fibre: 10.1)

    private func entry(syncID: UUID?, at seconds: TimeInterval = 1_758_400_000) -> LoggedFood {
        LoggedFood(food: oats, grams: 50, meal: .breakfast,
                   loggedAt: Date(timeIntervalSince1970: seconds), syncID: syncID)
    }

    func testASentFoodStaysUntilThePhoneAcknowledgesIt() {
        let log = StandaloneFoodLog(defaults: defaults)
        let id = UUID()
        log.append(entry(syncID: id))

        // Sent is not delivered: transferUserInfo may hold it for hours.
        XCTAssertEqual(log.entries.count, 1)

        XCTAssertTrue(log.acknowledge(syncID: id))
        XCTAssertTrue(log.entries.isEmpty)
    }

    func testTheAcknowledgementSurvivesARelaunch() {
        let id = UUID()
        StandaloneFoodLog(defaults: defaults).append(entry(syncID: id))
        StandaloneFoodLog(defaults: defaults).acknowledge(syncID: id)
        XCTAssertTrue(StandaloneFoodLog(defaults: defaults).entries.isEmpty)
    }

    func testOnlyTheAcknowledgedFoodLeaves() {
        let log = StandaloneFoodLog(defaults: defaults)
        let acknowledged = UUID()
        let stillInFlight = UUID()
        log.append(entry(syncID: acknowledged, at: 1_758_400_000))
        log.append(entry(syncID: stillInFlight, at: 1_758_400_060))
        log.append(entry(syncID: nil, at: 1_758_400_120))   // a library food: never sent

        log.acknowledge(syncID: acknowledged)

        XCTAssertEqual(log.entries.map(\.syncID), [stillInFlight, nil])
    }

    /// Two portions of the same food, logged in the same second, compare
    /// equal apart from their ids. Acknowledging one must leave the other.
    func testIdenticalPortionsAreToldApartByTheirIds() {
        let log = StandaloneFoodLog(defaults: defaults)
        let first = UUID()
        let second = UUID()
        log.append(entry(syncID: first))
        log.append(entry(syncID: second))

        log.acknowledge(syncID: first)

        XCTAssertEqual(log.entries.map(\.syncID), [second])
    }

    func testAnUnknownOrRepeatedAcknowledgementChangesNothing() {
        let log = StandaloneFoodLog(defaults: defaults)
        let id = UUID()
        log.append(entry(syncID: id))

        XCTAssertFalse(log.acknowledge(syncID: UUID()))   // e.g. a workout's ack
        XCTAssertEqual(log.entries.count, 1)

        XCTAssertTrue(log.acknowledge(syncID: id))
        XCTAssertFalse(log.acknowledge(syncID: id))       // delivered twice
        XCTAssertTrue(log.entries.isEmpty)
    }

    /// A food with no macros could not be kept for export and only counted
    /// as skipped ("can't be exported yet"). Once the phone has it, nothing
    /// was lost, so it stops counting.
    func testAnAcknowledgedSkipStopsCounting() {
        let log = StandaloneFoodLog(defaults: defaults)
        let sent = UUID()
        log.recordSkipped(syncID: sent)
        log.recordSkipped()                       // an older build's skip, no id
        XCTAssertEqual(log.skippedCount, 2)

        XCTAssertTrue(log.acknowledge(syncID: sent))
        XCTAssertEqual(log.skippedCount, 1)
        XCTAssertFalse(log.acknowledge(syncID: sent))
        XCTAssertEqual(log.skippedCount, 1)
    }

    func testClearForgetsPendingSkipsToo() {
        let log = StandaloneFoodLog(defaults: defaults)
        let sent = UUID()
        log.recordSkipped(syncID: sent)
        log.clear()
        XCTAssertFalse(log.acknowledge(syncID: sent))
        XCTAssertEqual(log.skippedCount, 0)
    }

    /// Entries written before `syncID` existed have no such key and must
    /// still load, and be exported, exactly as before.
    func testALogWrittenBeforeSyncIDsStillLoads() throws {
        let legacy = """
        {"entries":[{"food":{"name":"Oats, rolled, dry","kcal":379,"protein":13.2,"fat":6.5,
          "carbs":67.7,"fibre":10.1},"grams":50,"meal":"BREAKFAST",
          "loggedAt":"2026-09-20T08:00:00Z"}],"unreadable":[],"unreadableDropped":0}
        """
        defaults.set(Data(legacy.utf8), forKey: "com.dugcanlift.lift.standaloneFoodLog")
        let log = StandaloneFoodLog(defaults: defaults)
        let loaded = try XCTUnwrap(log.entries.first)
        XCTAssertNil(loaded.syncID)
        XCTAssertEqual(loaded.grams, 50)
        XCTAssertFalse(StandaloneExport.codes(for: log.entries).isEmpty)
    }

    /// The id rides only in local storage; the export payload is unchanged.
    func testTheExportIsTheSameWithOrWithoutAnID() {
        let at = Date(timeIntervalSince1970: 1_758_400_000)
        let with = [entry(syncID: UUID())]
        let without = [entry(syncID: nil)]
        XCTAssertEqual(StandaloneExport.codes(for: with, exportedAt: at),
                       StandaloneExport.codes(for: without, exportedAt: at))
    }
}
