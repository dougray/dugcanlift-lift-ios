import XCTest
@testable import LiftKit

/// The two ways this store used to destroy a whole log, and the guarantees that
/// replaced them. Issue #4: a watch that has never been paired holds the only
/// copy of this data, so an overwrite here is permanent.
final class StandaloneFoodLogDurabilityTests: XCTestCase {

    private var defaults: UserDefaults!
    private let suiteName = "StandaloneFoodLogDurabilityTests"
    private let key = "com.dugcanlift.lift.standaloneFoodLog"
    private let quarantineKey = "com.dugcanlift.lift.standaloneFoodLog.unreadable"

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

    private func entry(_ name: String = "Oats, rolled, dry", at date: Date) -> LoggedFood {
        LoggedFood(food: food(name), grams: 50, meal: .breakfast, loggedAt: date)
    }

    /// Writes whatever JSON text is given straight into the store's key, standing
    /// in for data a different build wrote.
    private func writeRaw(_ json: String) {
        defaults.set(Data(json.utf8), forKey: key)
    }

    private func storedEntryCount() -> Int {
        guard let data = defaults.data(forKey: key),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = object["entries"] as? [Any] else { return -1 }
        return entries.count
    }

    // MARK: - Defect 1: a wrong clock must not delete anything

    func testACorrectedClockDoesNotDeleteEntriesStampedWhileItWasWrong() {
        // The watch came back from a flat battery believing it was 2016 and the
        // user logged twice before it corrected itself.
        let confused = Date(timeIntervalSince1970: 1_460_000_000)  // April 2016
        let log = StandaloneFoodLog(defaults: defaults)
        log.append(entry("Banana", at: confused))
        log.append(entry("Milk", at: confused.addingTimeInterval(60)))

        // The clock corrects itself, and the next food is logged with a true date.
        let corrected = StandaloneFoodLog(defaults: defaults)
        corrected.append(entry("Eggs", at: .now))

        XCTAssertEqual(corrected.entries.count, 3,
                       "entries stamped by a confused clock must survive it being corrected")
        XCTAssertTrue(corrected.entries.contains { $0.food.name == "Banana" })
        XCTAssertTrue(corrected.entries.contains { $0.food.name == "Milk" })
    }

    func testAgeNeverRemovesAnythingFromStorage() {
        let ancient = Date(timeIntervalSinceNow: -400 * 86_400)
        let log = StandaloneFoodLog(defaults: defaults)
        log.append(entry("Ancient", at: ancient))
        log.append(entry("Fresh", at: .now))

        XCTAssertEqual(storedEntryCount(), 2, "the write path must not drop by date")
        XCTAssertEqual(log.entries.count, 2)
    }

    func testAnEntryOlderThanSixtyDaysIsStillExported() {
        // Settled 2026-09-13: age hides nothing. A watch out of contact for two
        // months hands over everything it recorded.
        let log = StandaloneFoodLog(defaults: defaults)
        log.append(entry("Ninety days old", at: Date(timeIntervalSinceNow: -90 * 86_400)))
        log.append(entry("Recent", at: .now))

        XCTAssertEqual(log.entries.count, 2)
        XCTAssertEqual(log.entries.map(\.food.name), ["Ninety days old", "Recent"],
                       "oldest first, both present")
    }

    func testAnEntryStampedInTheFutureIsAlsoJustAnEntry() {
        let log = StandaloneFoodLog(defaults: defaults)
        log.append(entry("Ahead", at: Date(timeIntervalSinceNow: 5 * 86_400)))
        log.append(entry("Now", at: .now))

        XCTAssertEqual(log.entries.count, 2, "no clock reading decides what may be seen")
    }

    // MARK: - Defect 2: one unreadable entry must not destroy the rest

    func testEntriesThisBuildCannotDecodeAreKeptNotDropped() {
        // The middle entry carries no `grams`, as a build that renamed the field
        // would leave it.
        writeRaw("""
        [
          {"food":{"name":"A","kcal":1,"protein":0,"fat":0,"carbs":0,"fibre":0},"grams":10,"meal":"BREAKFAST","loggedAt":"2026-09-10T08:00:00Z"},
          {"food":{"name":"B","kcal":1,"protein":0,"fat":0,"carbs":0,"fibre":0},"meal":"LUNCH","loggedAt":"2026-09-10T12:00:00Z"},
          {"food":{"name":"C","kcal":1,"protein":0,"fat":0,"carbs":0,"fibre":0},"grams":30,"meal":"DINNER","loggedAt":"2026-09-10T18:00:00Z"}
        ]
        """)

        let log = StandaloneFoodLog(defaults: defaults)
        XCTAssertEqual(log.entries.count, 2, "the two readable entries still load")
        XCTAssertEqual(log.unreadableCount, 1, "the third is counted, not silently gone")

        // Logging again must not overwrite what this build could not read.
        log.append(entry("D", at: Date(timeIntervalSince1970: 1_789_000_000)))
        XCTAssertEqual(log.unreadableCount, 1, "the unreadable entry survives a write")

        let reopened = StandaloneFoodLog(defaults: defaults)
        XCTAssertEqual(reopened.entries.count, 3)
        XCTAssertEqual(reopened.unreadableCount, 1)
    }

    func testAnUnreadableEntryRejoinsTheLogOnceABuildUnderstandsItAgain() {
        // Carried forward verbatim, so a build that understands the shape again
        // gets the data back rather than a tombstone.
        writeRaw("""
        [
          {"food":{"name":"B","kcal":1,"protein":0,"fat":0,"carbs":0,"fibre":0},"meal":"LUNCH","loggedAt":"2026-09-10T12:00:00Z"}
        ]
        """)
        let log = StandaloneFoodLog(defaults: defaults)
        XCTAssertEqual(log.unreadableCount, 1)
        log.append(entry("New", at: Date(timeIntervalSince1970: 1_789_000_000)))

        // The raw JSON of the entry this build could not read is still in storage.
        let data = defaults.data(forKey: key)!
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("\"LUNCH\""),
                      "the unreadable entry's own JSON must be carried through the write")
    }

    func testAWhollyUnreadableBlobIsSetAsideBeforeAnythingReplacesIt() {
        writeRaw("this is not json at all")

        let log = StandaloneFoodLog(defaults: defaults)
        XCTAssertEqual(log.entries.count, 0)
        log.append(entry("First after corruption", at: .now))

        XCTAssertNotNil(defaults.data(forKey: quarantineKey),
                        "the bytes that could not be read are kept, not overwritten")
        XCTAssertEqual(log.entries.count, 1)
    }

    // MARK: - The format change must not itself lose anything

    func testALogWrittenByTheOldBuildStillLoads() {
        // The previous format was a bare array at the same key.
        writeRaw("""
        [
          {"food":{"name":"Legacy","kcal":1,"protein":0,"fat":0,"carbs":0,"fibre":0},"grams":10,"meal":"BREAKFAST","loggedAt":"2026-09-10T08:00:00Z"}
        ]
        """)
        let log = StandaloneFoodLog(defaults: defaults)
        XCTAssertEqual(log.entries.count, 1)
        XCTAssertEqual(log.entries.first?.food.name, "Legacy")
    }

    // MARK: - The count cap is the only thing that may drop an entry

    func testTheCountCapStillDropsOldestFirst() {
        let log = StandaloneFoodLog(defaults: defaults, maxEntries: 3)
        for i in 0..<5 {
            log.append(entry("Food \(i)", at: Date(timeIntervalSince1970: 1_789_000_000 + Double(i))))
        }
        XCTAssertEqual(log.entries.count, 3)
        XCTAssertEqual(log.entries.map(\.food.name), ["Food 2", "Food 3", "Food 4"])
    }
}

/// Export's empty state has three meanings and must not collapse them into
/// "nothing logged" — see `exportEmptyMessage`.
final class ExportEmptyMessageTests: XCTestCase {

    func testNothingEverLogged() {
        XCTAssertEqual(exportEmptyMessage(skippedCount: 0),
                       "Nothing logged yet.")
    }

    func testSkippedEntriesReadNaturallyAtOne() {
        XCTAssertEqual(exportEmptyMessage(skippedCount: 1),
                       "1 entry can't be exported yet. Update LIFT on your iPhone.")
        XCTAssertEqual(exportEmptyMessage(skippedCount: 3),
                       "3 entries can't be exported yet. Update LIFT on your iPhone.")
    }
}
